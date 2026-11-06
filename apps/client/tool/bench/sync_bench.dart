// Disposable resource-usage benchmark for the Linux sync worker (Feature #14).
//
// Drives the real SyncEngine / RootTree / Manifest / projection code against a
// synthetic temporary root and an in-memory synthetic cloud listing. It never
// contacts a server, pairs, or reads real profiles. Product code is unchanged:
// the instrumentation lives in subclasses defined here.
//
//   dart run tool/bench/sync_bench.dart --files 1000 --work DIR --out FILE.json
//
// See "Resource baseline harness" in apps/client/README.md for modes/caveats.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

const _marker = '.anj-sync-bench-fixture';

int _now() => DateTime.now().microsecondsSinceEpoch;

// ---------------------------------------------------------------- /proc/self

/// getrusage(RUSAGE_SELF): CPU in microseconds and context switches summed
/// over every thread of the process, including threads that already exited.
/// Linux x86_64/arm64 `struct rusage` is 18 longs: utime{sec,usec},
/// stime{sec,usec}, then maxrss .. nivcsw (nvcsw = 16, nivcsw = 17).
final _getrusage = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Int32, Pointer<Int64>),
      int Function(int, Pointer<Int64>)
    >('getrusage');

class Proc {
  Proc._(this.values);
  final Map<String, int> values;

  static Map<String, String> _kv(String text) => {
    for (final line in text.split('\n'))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  };

  static int _kb(String? v) => v == null ? 0 : int.parse(v.split(' ').first);

  static Proc read() {
    final usage = calloc<Int64>(18);
    try {
      if (_getrusage(0, usage) != 0) {
        throw const OSError('getrusage failed');
      }
      final status = _kv(File('/proc/self/status').readAsStringSync());
      final io = _kv(File('/proc/self/io').readAsStringSync());
      final utimeUs = usage[0] * 1000000 + usage[1];
      final stimeUs = usage[2] * 1000000 + usage[3];
      return Proc._({
        't_us': _now(),
        'utime_us': utimeUs,
        'stime_us': stimeUs,
        'utime_ms': utimeUs ~/ 1000,
        'stime_ms': stimeUs ~/ 1000,
        'rss_kb': _kb(status['VmRSS']),
        'hwm_kb': _kb(status['VmHWM']),
        'threads': int.parse(status['Threads']!),
        'rchar': int.parse(io['rchar']!),
        'wchar': int.parse(io['wchar']!),
        'syscr': int.parse(io['syscr']!),
        'syscw': int.parse(io['syscw']!),
        'read_bytes': int.parse(io['read_bytes']!),
        'write_bytes': int.parse(io['write_bytes']!),
        'vol_ctxt': usage[16],
        'invol_ctxt': usage[17],
      });
    } finally {
      calloc.free(usage);
    }
  }

  int get cpuUs => values['utime_us']! + values['stime_us']!;

  /// Resets VmHWM so the next reading is the peak of the following phase.
  static void resetPeak() {
    try {
      final f = File('/proc/self/clear_refs')
          .openSync(mode: FileMode.writeOnlyAppend);
      f.writeStringSync('5');
      f.closeSync();
    } on FileSystemException {
      // Older kernels: peak stays process-lifetime; reported as such.
    }
  }

  Map<String, Object> delta(Proc before) {
    final d = <String, Object>{};
    for (final k in [
      'utime_us',
      'stime_us',
      'utime_ms',
      'stime_ms',
      'rchar',
      'wchar',
      'syscr',
      'syscw',
      'read_bytes',
      'write_bytes',
      'vol_ctxt',
      'invol_ctxt',
    ]) {
      d[k] = values[k]! - before.values[k]!;
    }
    d['wall_s'] = (values['t_us']! - before.values['t_us']!) / 1e6;
    d['cpu_s'] = (cpuUs - before.cpuUs) / 1e6;
    d['rss_kb'] = values['rss_kb']!;
    d['peak_rss_kb'] = values['hwm_kb']!;
    d['threads'] = values['threads']!;
    return d;
  }
}

Map<String, Object> rates(Map<String, Object> d) {
  final wall = d['wall_s'] as double;
  double r(String k) => (d[k] as int) / wall;
  return {
    ...d,
    'cpu_pct': 100 * (d['cpu_s'] as double) / wall,
    'rchar_per_s': r('rchar').round(),
    'wchar_per_s': r('wchar').round(),
    'read_bytes_per_s': r('read_bytes').round(),
    'write_bytes_per_s': r('write_bytes').round(),
    'ctxt_per_s': double.parse(
      ((r('vol_ctxt') + r('invol_ctxt'))).toStringAsFixed(1),
    ),
  };
}

// ------------------------------------------------------------ instrumentation

class BudgetExceeded implements Exception {
  @override
  String toString() => 'bench tick budget exceeded';
}

/// Counts and times every full manifest rewrite (SQLite, synchronous=FULL).
/// With [deadlineUs] set, a save after the deadline (once the per-path loop
/// has started) throws [BudgetExceeded] before writing, ending the pass early
/// so an O(N^2) pass can be sampled and extrapolated instead of run for hours.
/// Every throw is counted, so a pass is never reported complete if product
/// code caught one and carried on without writing.
/// [rowsWritten] reads SQLite total_changes() on this connection: rows
/// inserted/updated/deleted by any write path, not only save().
class CountingManifest extends Manifest {
  CountingManifest(super.profile);
  int? deadlineUs;
  int budgetThrows = 0;
  int saves = 0;
  int get rowsWritten =>
      db.select('SELECT total_changes() AS c').first['c'] as int;
  int saveUs = 0;
  int _lastProgress = 0;
  int? progressTotal;
  @override
  void save({Map<String, String> settings = const {}}) {
    final start = _now();
    if (deadlineUs != null && start > deadlineUs! && saves >= 2) {
      budgetThrows++;
      throw BudgetExceeded();
    }
    super.save(settings: settings);
    final end = _now();
    saves++;
    saveUs += end - start;
    if (progressTotal != null && end - _lastProgress > 30e6) {
      _lastProgress = end;
      stderr.writeln(
        '[progress] saves=$saves/~$progressTotal '
        'save_s=${(saveUs / 1e6).toStringAsFixed(1)} '
        'last_save_ms=${((end - start) / 1e3).toStringAsFixed(1)}',
      );
    }
  }

  void reset() {
    saves = 0;
    saveUs = 0;
    budgetThrows = 0;
  }
}

/// Times the full local scan + SHA-256 of every file, with its CPU and rchar.
class TimedRootTree extends RootTree {
  TimedRootTree(super.root, super.staging, super.native);
  int scans = 0;
  int scanUs = 0;
  int scanCpuUs = 0;
  int scanRchar = 0;
  final List<(int, int)> scanWindows = [];
  @override
  Future<Map<String, LocalItem>> snapshot({
    bool includeExcluded = false,
  }) async {
    final before = Proc.read();
    final result = await super.snapshot(includeExcluded: includeExcluded);
    final after = Proc.read();
    final start = before.values['t_us']!, end = after.values['t_us']!;
    scans++;
    scanUs += end - start;
    scanCpuUs += after.cpuUs - before.cpuUs;
    scanRchar += after.values['rchar']! - before.values['rchar']!;
    scanWindows.add((start, end));
    return result;
  }

  void reset() {
    scans = 0;
    scanUs = 0;
    scanCpuUs = 0;
    scanRchar = 0;
  }
}

/// In-memory listing equal to the seeded manifest: the steady "in sync" state.
/// Uploads are acknowledged without retaining bytes (they stream the staged
/// file once to model the read). Any other mutation is unexpected here.
class SyntheticCloud implements CloudApi {
  final Map<String, RemoteItem> items = {};
  int snapshots = 0;
  int snapshotUs = 0;
  int uploads = 0;
  int unexpected = 0;
  int _version = 0;
  final Map<String, int> uploadDispatchUs = {};
  @override
  Future<List<RemoteItem>> snapshot() async {
    final start = _now();
    final result = items.values.toList();
    snapshots++;
    snapshotUs += _now() - start;
    return result;
  }

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    uploadDispatchUs[path] ??= _now();
    uploads++;
    if (items[path]?.etag != etag) {
      throw const CloudFailure('bench version changed', status: 412);
    }
    var size = 0;
    await for (final chunk in source.openRead()) {
      size += chunk.length;
    }
    final version = '"bench-upload-${++_version}"';
    items[path] = RemoteItem(path, ItemKind.file, version, size: size);
    return version;
  }

  /// Versions come from the (synthetic) upload response itself.
  @override
  bool get lastUploadReadBack => false;
  @override
  int? get uploadLimit => null;

  Never _unexpected(String what) {
    unexpected++;
    throw CloudFailure('bench: unexpected $what');
  }

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async => _unexpected('download $path');
  @override
  Future<void> mkdir(String path) async => _unexpected('mkdir $path');
  @override
  Future<void> deleteFile(String path, {required String etag}) async =>
      _unexpected('deleteFile $path');
  @override
  Future<void> move(String from, String to, {required String etag}) async =>
      _unexpected('move $from');
  @override
  bool get safeFolderDeletion => false;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async => _unexpected('deleteFolder $path');
  @override
  Future<AddedPage?> addedSince(int after) async => null;
  @override
  void close() {}
}

// ------------------------------------------------------------------- fixture

class Spec {
  Spec(this.files, this.seed);
  final int files;
  final int seed;

  /// 80% 1-16 KiB, 18% 16-256 KiB, 2% 256 KiB-2 MiB (mean about 54 KiB).
  List<int> sizes() {
    final random = Random(seed);
    int between(int lo, int hi) => lo + random.nextInt(hi - lo);
    return List.generate(files, (_) {
      final roll = random.nextInt(100);
      if (roll < 80) return between(1024, 16 * 1024);
      if (roll < 98) return between(16 * 1024, 256 * 1024);
      return between(256 * 1024, 2 * 1024 * 1024);
    });
  }

  /// Nested directories under the three default folders, 40 files per leaf.
  String path(int i) {
    final leaf = i ~/ 40;
    final top = const ['Documents', 'Music', 'Videos'][leaf % 3];
    return '$top/g${(leaf ~/ 3) ~/ 16}/d${leaf ~/ 3}/f$i.bin';
  }
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) throw ArgumentError('Unexpected ${args[i]}');
    final key = args[i].substring(2);
    if (key == 'keep') {
      options[key] = 'true';
    } else {
      options[key] = args[++i];
    }
  }
  final files = int.parse(options['files'] ?? '1000');
  final work = Directory(options['work'] ?? (throw ArgumentError('--work')));
  final out = File(options['out'] ?? '${work.path}/sync_bench_$files.json');
  final onlineTicks = int.parse(options['online-ticks'] ?? '3');
  final idleSeconds = int.parse(options['idle-seconds'] ?? '60');
  final offlineSeconds = int.parse(options['offline-seconds'] ?? '60');
  final probes = int.parse(options['probes'] ?? '3');
  final tickBudget = int.parse(options['tick-budget-seconds'] ?? '0');
  final keep = options['keep'] == 'true';
  final library =
      options['native-library'] ??
      Platform.environment['ANJ_ROOTFS_LIBRARY'] ??
      '${Directory.current.path}/.dart_tool/libanj_rootfs.so';

  final fixture = Directory('${work.path}/fixture-$files');
  if (fixture.existsSync()) {
    if (!File('${fixture.path}/$_marker').existsSync()) {
      throw StateError('Refusing to reuse a non-fixture directory.');
    }
    fixture.deleteSync(recursive: true);
  }
  fixture.createSync(recursive: true);
  File('${fixture.path}/$_marker').writeAsStringSync('synthetic only\n');
  final workFs = (await Process.run('stat', [
    '-f',
    '-c',
    '%T',
    work.path,
  ])).stdout.toString().trim();
  if (workFs == 'tmpfs' || workFs == 'ramfs') {
    stderr.writeln(
      '[warning] --work is on $workFs: read_bytes/write_bytes and fsync cost '
      'do not reflect a disk. Use the same disk filesystem before and after.',
    );
  }
  final result = <String, Object?>{
    'files': files,
    'source': await _source(),
    'work_filesystem': workFs,
    'runtime': Platform.version,
    'executable': Platform.resolvedExecutable,
    'started': DateTime.now().toUtc().toIso8601String(),
    'options': options,
    'baseline_process': Proc.read().values,
  };
  void write() {
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  }

  // Remove the marker-guarded fixture on normal exit, on an exception, and on
  // SIGINT/SIGTERM (handled when the event loop next runs; SIGKILL cannot be).
  var removed = false;
  void cleanup() {
    if (keep || removed) return;
    try {
      if (File('${fixture.path}/$_marker').existsSync()) {
        fixture.deleteSync(recursive: true);
      }
      removed = true;
    } on FileSystemException catch (error) {
      stderr.writeln('[cleanup] could not remove ${fixture.path}: $error');
    }
  }

  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((received) {
      stderr.writeln('[signal] $received: removing fixture');
      cleanup();
      result['interrupted'] = '$received';
      result['fixture_removed'] = removed;
      write();
      exit(received == ProcessSignal.sigint ? 130 : 143);
    });
  }
  try {
    final native = NativeRootFs(library);
    native.privateDir(fixture.path);
    final profile = Directory('${fixture.path}/profile')..createSync();
    native.privateDir(profile.path);
    final parent = Directory('${fixture.path}/files')..createSync();
    RootTree.setup(parent.path, 'bench', native).close();
    final rootPath = '${parent.path}/anj-cloud';
    final stagingPath = '${parent.path}/.anj-cloud-bench';

    // ---- generate
    final spec = Spec(files, 1409);
    final sizes = spec.sizes();
    final pool = Uint8List(4 * 1024 * 1024);
    final random = Random(spec.seed);
    for (var i = 0; i < pool.length; i++) {
      pool[i] = random.nextInt(256);
    }
    var genStart = _now();
    var totalBytes = 0;
    final dirs = <String>{};
    for (var i = 0; i < files; i++) {
      final path = spec.path(i);
      final dir = path.substring(0, path.lastIndexOf('/'));
      if (dirs.add(dir)) {
        Directory('$rootPath/$dir').createSync(recursive: true);
      }
      final size = sizes[i];
      final bytes = Uint8List(size);
      final offset = random.nextInt(pool.length);
      for (var o = 0; o < size;) {
        final start = (offset + o) % pool.length;
        final n = min(size - o, pool.length - start);
        bytes.setRange(o, o + n, pool, start);
        o += n;
      }
      final header = utf8.encode('anj-bench file $i of $files\n');
      bytes.setRange(0, min(header.length, size), header);
      File('$rootPath/$path').writeAsBytesSync(bytes);
      totalBytes += size;
    }
    result['fixture'] = {
      'root': rootPath,
      'files': files,
      'leaf_directories': dirs.length,
      'total_bytes': totalBytes,
      'generate_s': (_now() - genStart) / 1e6,
      'size_distribution':
          '80% 1-16KiB, 18% 16-256KiB, 2% 256KiB-2MiB, seed ${spec.seed}',
    };
    stderr.writeln('[fixture] ${jsonEncode(result['fixture'])}');

    // ---- seed an already-synchronized manifest and matching listing
    final manifest = CountingManifest(profile);
    manifest.setSetting('profileId', 'bench');
    manifest.setSetting('root', rootPath);
    manifest.setSetting('staging', stagingPath);
    final tree = TimedRootTree(
      Directory(rootPath),
      Directory(stagingPath),
      native,
    );
    manifest.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
    final cloud = SyntheticCloud();
    var seedStart = _now();
    final scan = await tree.snapshot();
    final digest = _DigestSink();
    final listDigest = sha256.startChunkedConversion(digest);
    for (final item
        in scan.values.toList()..sort((a, b) => a.path.compareTo(b.path))) {
      final etag = item.kind == ItemKind.directory
          ? '"bench-dir-${item.path}"'
          : '"bench-${item.hash!.substring(0, 16)}"';
      manifest.entries[item.path] = Entry(item.path, item.kind)
        ..etag = etag
        ..baselineHash = item.hash
        ..localHash = item.hash
        ..expectedPresent = true
        ..status = 'current local'
        ..size = item.size;
      cloud.items[item.path] = RemoteItem(
        item.path,
        item.kind,
        etag,
        size: item.size,
      );
      listDigest.add(utf8.encode('${item.path}\t${item.hash}\n'));
    }
    listDigest.close();
    manifest.save();
    result['seed'] = {
      'entries': manifest.entries.length,
      'directories': scan.values
          .where((v) => v.kind == ItemKind.directory)
          .length,
      'first_hash_scan_s': tree.scanUs / 1e6,
      'seed_total_s': (_now() - seedStart) / 1e6,
      'fixture_digest_sha256': digest.value.toString(),
    };
    stderr.writeln('[seed] ${jsonEncode(result['seed'])}');
    write();

    // ---- emit: a COPY of worker.dart's emit() at b35f858 (projectEntry for
    // every entry, sent to another isolate). It will not follow changes to
    // the worker's emit, e.g. emit-on-change; gate on offline_worker_idle.
    final sink = ReceivePort();
    var sinkStates = 0;
    final sinkIsolatePort = Completer<SendPort>();
    sink.listen((message) {
      if (message is SendPort) {
        sinkIsolatePort.complete(message);
      } else {
        sinkStates++;
      }
    });
    await Isolate.spawn(_sinkIsolate, sink.sendPort);
    final uiPort = await sinkIsolatePort.future;
    final engine = SyncEngine(manifest, tree, cloud);
    Future<int> emit() async {
      final start = _now();
      final entries = <Map<String, Object?>>[];
      for (final entry in manifest.entries.values) {
        entries.add(await projectEntry(engine, entry));
      }
      uiPort.send({
        'event': 'state',
        'message': engine.message,
        'passes': engine.passes,
        'entries': entries,
        'operations': manifest.operations.length,
      });
      return _now() - start;
    }

    // ---- components
    final components = <String, Object>{};
    tree.reset();
    var before = Proc.read();
    await tree.snapshot(includeExcluded: true);
    components['local_scan_hash_warm'] = Proc.read().delta(before);
    final evict = await Process.run('python3', [
      '-I',
      '-c',
      _dropCache,
      rootPath,
    ]);
    components['page_cache_evicted_files'] = evict.stdout.toString().trim();
    before = Proc.read();
    await tree.snapshot(includeExcluded: true);
    components['local_scan_hash_cold'] = Proc.read().delta(before);
    manifest.reset();
    before = Proc.read();
    var rows = manifest.rowsWritten;
    for (var i = 0; i < 3; i++) {
      manifest.save();
    }
    components['manifest_save_x3'] = Proc.read().delta(before)
      ..['rows_written'] = manifest.rowsWritten - rows;
    components['manifest_save_ms_each'] = manifest.saveUs / 3 / 1e3;
    before = Proc.read();
    final emitUs = await emit();
    components['emit'] = Proc.read().delta(before)..['emit_ms'] = emitUs / 1e3;
    components['remote_listing_items'] = cloud.items.length;
    components['remote_propfind_requests_per_cycle'] =
        cloud.items.values.where((v) => v.kind == ItemKind.directory).length +
        1;
    result['components'] = components;
    stderr.writeln('[components] ${jsonEncode(components)}');
    write();

    // ---- online ticks (synthetic cloud, steady in-sync state)
    final ticks = <Map<String, Object>>[];
    result['online_ticks'] = ticks;
    manifest.progressTotal = manifest.entries.length;
    for (var i = 0; i < onlineTicks; i++) {
      manifest.reset();
      tree.reset();
      cloud.snapshotUs = 0;
      Proc.resetPeak();
      rows = manifest.rowsWritten;
      before = Proc.read();
      manifest.deadlineUs = tickBudget > 0
          ? before.values['t_us']! + tickBudget * 1000000
          : null;
      var caught = false;
      try {
        await engine.tick();
      } on BudgetExceeded {
        caught = true;
      }
      manifest.deadlineUs = null;
      final d = rates(Proc.read().delta(before));
      final completed = !caught && manifest.budgetThrows == 0;
      d
        ..['completed'] = completed
        ..['budget_throws'] = manifest.budgetThrows
        ..['rows_written'] = manifest.rowsWritten - rows
        ..['local_scan_cpu_s'] = tree.scanCpuUs / 1e6
        ..['local_scan_rchar'] = tree.scanRchar
        // Measured values are exact for a completed pass and lower bounds for
        // a pass cut by the budget.
        ..['cpu_s_is_lower_bound'] = !completed;
      if (!completed && manifest.saves > 1) {
        // Valid only for the per-file-save design this budget interrupts: save
        // 1 follows the local pass, then one save per reconciled file path
        // (directory paths skip it). The scan is counted once; the rest of the
        // pass is scaled linearly by files reconciled.
        final loopSaves = manifest.saves - 1;
        double scale(num total, num scanPart) =>
            scanPart + (total - scanPart) / loopSaves * (files + 1);
        final loopS = d['wall_s'] as double;
        final perPath =
            (loopS - tree.scanUs / 1e6 - cloud.snapshotUs / 1e6) / loopSaves;
        d
          ..['extrapolation_basis'] = 'per-file manifest save'
          ..['paths_reconciled'] = loopSaves
          ..['per_path_s'] = perPath
          ..['extrapolated_full_pass_s'] =
              tree.scanUs / 1e6 + perPath * (files + 1)
          ..['extrapolated_cpu_s'] = scale(
            d['cpu_s'] as double,
            tree.scanCpuUs / 1e6,
          )
          ..['extrapolated_rchar'] = scale(
            d['rchar'] as int,
            tree.scanRchar,
          ).round()
          ..['extrapolated_rows_written'] = scale(
            d['rows_written'] as int,
            0,
          ).round()
          ..['extrapolated_write_bytes'] = scale(
            d['write_bytes'] as int,
            0,
          ).round();
      }
      final eUs = await emit();
      d
        ..['manifest_saves'] = manifest.saves
        ..['manifest_save_s'] = manifest.saveUs / 1e6
        ..['local_scan_s'] = tree.scanUs / 1e6
        ..['remote_snapshot_s'] = cloud.snapshotUs / 1e6
        ..['emit_s'] = eUs / 1e6
        ..['engine_message'] = engine.message
        ..['operations_after'] = manifest.operations.length
        ..['uploads'] = cloud.uploads
        ..['unexpected_cloud_calls'] = cloud.unexpected;
      ticks.add(d);
      stderr.writeln('[tick ${i + 1}] ${jsonEncode(d)}');
      write();
    }
    manifest.progressTotal = null;

    // ---- idle loop: a REPLICA of worker.dart's 2 s Timer.periodic + tick +
    // emit at b35f858. It will not follow scheduling changes; gate on
    // online_ticks (real SyncEngine.tick) and offline_worker_idle instead.
    final aborted = ticks.any((t) => t['completed'] == false);
    if (aborted) {
      result['online_idle'] = {
        'skipped':
            'A single pass exceeded the tick budget, so the worker would run '
            'passes back to back; online_ticks rates are the steady state.',
      };
    }
    if (idleSeconds > 0 && !aborted) {
      final writes = <String, int>{};
      final probeDone = ReceivePort();
      final probeTargets = [
        for (var k = 0; k < probes; k++)
          spec.path((files ~/ (probes + 1)) * (k + 1)),
      ];
      final probeEvents = <Object?>[];
      probeDone.listen((message) {
        final m = message as Map;
        writes[m['path'] as String] = m['written_us'] as int;
        probeEvents.add(m);
      });
      if (probes > 0) {
        await Isolate.spawn(_probeIsolate, {
          'port': probeDone.sendPort,
          'root': rootPath,
          'paths': probeTargets,
          'interval_ms': idleSeconds * 1000 ~/ (probes + 2),
        });
      }
      manifest.reset();
      tree.reset();
      tree.scanWindows.clear();
      final cycles = <int>[];
      Proc.resetPeak();
      rows = manifest.rowsWritten;
      before = Proc.read();
      final input = ReceivePort();
      var scheduled = false;
      final timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!scheduled) {
          scheduled = true;
          input.sendPort.send('tick');
        }
      });
      final stop = Timer(Duration(seconds: idleSeconds), () {
        input.sendPort.send('stop');
      });
      input.sendPort.send('tick');
      await for (final message in input) {
        if (message == 'stop') break;
        final start = _now();
        await engine.tick();
        scheduled = false;
        await emit();
        cycles.add(_now() - start);
      }
      timer.cancel();
      stop.cancel();
      input.close();
      probeDone.close();
      final d = rates(Proc.read().delta(before));
      final latencies = <Map<String, Object?>>[];
      for (final entry in writes.entries) {
        final noticed = tree.scanWindows
            .where((w) => w.$1 >= entry.value)
            .map((w) => w.$2)
            .firstOrNull;
        final dispatched = cloud.uploadDispatchUs[entry.key];
        latencies.add({
          'path': entry.key,
          'scan_complete_after_write_s': noticed == null
              ? null
              : (noticed - entry.value) / 1e6,
          'upload_dispatch_after_write_s': dispatched == null
              ? null
              : (dispatched - entry.value) / 1e6,
        });
      }
      result['online_idle'] = {
        ...d,
        'replica_of':
            'worker.dart Timer.periodic(2 s) + tick + emit at b35f858',
        'rows_written': manifest.rowsWritten - rows,
        'cycles': cycles.length,
        'cycle_s': [for (final c in cycles) c / 1e6],
        'manifest_saves': manifest.saves,
        'manifest_save_s': manifest.saveUs / 1e6,
        'local_scan_s': tree.scanUs / 1e6,
        'emitted_states': sinkStates,
        'uploads': cloud.uploads,
        'unexpected_cloud_calls': cloud.unexpected,
        'probe_latency': latencies,
        'probe_events': probeEvents,
      };
      stderr.writeln('[online_idle] ${jsonEncode(result['online_idle'])}');
      write();
    }
    // ---- watched worker loop (spec #15): the real WorkerLoop with inotify
    // and the synthetic cloud, idle over a window that should span the
    // confirmation margin M, then single-save probes (fresh file written to
    // upload dispatch). The tail window is the steady state after M.
    var engineClosed = false;
    final watchedSeconds = int.parse(options['watched-seconds'] ?? '0');
    final saveProbes = int.parse(options['save-probes'] ?? '10');
    if (watchedSeconds > 0 && !aborted) {
      await engine.startWatching();
      final watcher = engine.watcher as LocalWatcher?;
      final meter = tree.native.meter;
      final scanFiles = meter.filesBy['scan'] ?? 0;
      final passes = engine.passes;
      final fullScans = engine.fullScans;
      manifest.reset();
      tree.reset();
      Proc.resetPeak();
      rows = manifest.rowsWritten;
      final input = StreamController<Object?>();
      final metricsPath = Platform.environment['ANJ_CLIENT_METRICS'];
      final loop = WorkerLoop(
        engine,
        (_) {},
        metrics: metricsPath == null ? null : File(metricsPath),
      );
      before = Proc.read();
      final running = loop.run(input.stream);
      final tailSeconds = min(60, watchedSeconds ~/ 2);
      await Future<void>.delayed(
        Duration(seconds: watchedSeconds - tailSeconds),
      );
      final tailStart = Proc.read();
      final tailPasses = engine.passes;
      final tailScans = engine.fullScans;
      final tailHashed = meter.filesBy['scan'] ?? 0;
      await Future<void>.delayed(Duration(seconds: tailSeconds));
      final idle = rates(Proc.read().delta(before));
      final tail = rates(Proc.read().delta(tailStart));
      final idleRows = manifest.rowsWritten - rows;
      // Counters at the end of the idle window, before the save probes.
      final idlePasses = engine.passes - passes;
      final idleScans = engine.fullScans - fullScans;
      final idleHashed = (meter.filesBy['scan'] ?? 0) - scanFiles;
      final tailCounts = {
        'passes': engine.passes - tailPasses,
        'full_stat_scans': engine.fullScans - tailScans,
        'scan_files_hashed': (meter.filesBy['scan'] ?? 0) - tailHashed,
      };
      final latencies = <double?>[];
      final random = Random(7);
      for (var k = 0; k < saveProbes; k++) {
        // Random phase against the 2 s pass deadline.
        await Future<void>.delayed(
          Duration(milliseconds: 2500 + random.nextInt(2000)),
        );
        final path = 'Documents/watch-probe-$k.bin';
        final written = _now();
        File('$rootPath/$path').writeAsBytesSync(
          List<int>.generate(4096, (i) => (i * 31 + k) & 0xff),
          flush: true,
        );
        while (cloud.uploadDispatchUs[path] == null &&
            _now() - written < 30e6) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final dispatched = cloud.uploadDispatchUs[path];
        latencies.add(dispatched == null ? null : (dispatched - written) / 1e6);
      }
      input.add({'action': 'stop'});
      await running;
      engineClosed = true;
      final measured = latencies.whereType<double>().toList()..sort();
      result['watched_idle'] = {
        ...idle,
        'watcher': watcher == null
            ? 'unavailable'
            : {
                'events': watcher.events,
                'watches': watcher.watches,
                'unwatched': watcher.unwatched,
                'overflows': watcher.overflows,
              },
        'confirm_margin_s': tree.confirmMicros / 1e6,
        'passes': idlePasses,
        'full_stat_scans': idleScans,
        'scan_files_hashed': idleHashed,
        'rows_written': idleRows,
        'tail': {...tail, ...tailCounts},
        'save_to_upload_dispatch_s': latencies,
        'save_to_upload_dispatch_median_s': measured.isEmpty
            ? null
            : measured[measured.length ~/ 2],
        'message': engine.message,
      };
      stderr.writeln('[watched_idle] ${jsonEncode(result['watched_idle'])}');
      write();
    }
    // Closes the synthetic cloud, root descriptors and manifest (profile lock).
    if (!engineClosed) engine.close();
    sink.close();

    // ---- real worker isolate, unpaired (DisconnectedCloud): product loop as is
    if (offlineSeconds > 0) {
      final output = ReceivePort();
      var states = 0;
      var lastEntries = 0;
      var lastMessage = '';
      SendPort? workerInput;
      final stopped = Completer<void>();
      final ready = Completer<void>();
      final stateTimes = <int>[];
      output.listen((message) {
        final m = message as Map;
        switch (m['event']) {
          case 'ready':
            workerInput = m['input'] as SendPort;
            ready.complete();
          case 'state':
            states++;
            stateTimes.add(_now());
            lastEntries = (m['entries'] as List).length;
            lastMessage = m['message'] as String;
          case 'fatal':
            lastMessage = 'fatal: ${m['message']}';
            if (!ready.isCompleted) ready.complete();
            if (!stopped.isCompleted) stopped.complete();
          case 'stopped':
            if (!stopped.isCompleted) stopped.complete();
        }
      });
      Proc.resetPeak();
      before = Proc.read();
      await Isolate.spawn(syncWorker, {
        'output': output.sendPort,
        'nativeLibrary': library,
        'profile': profile.path,
        'privateKey': null,
      });
      await ready.future;
      await Future<void>.delayed(Duration(seconds: offlineSeconds));
      workerInput?.send({'action': 'stop'});
      final d = rates(Proc.read().delta(before));
      await stopped.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () {},
      );
      output.close();
      final gaps = [
        for (var i = 1; i < stateTimes.length; i++)
          (stateTimes[i] - stateTimes[i - 1]) / 1e6,
      ];
      result['offline_worker_idle'] = {
        ...d,
        'states': states,
        'state_interval_s': gaps,
        'entries_per_state': lastEntries,
        'message': lastMessage,
      };
      stderr.writeln(
        '[offline_worker_idle] ${jsonEncode(result['offline_worker_idle'])}',
      );
    }
    result['finished'] = DateTime.now().toUtc().toIso8601String();
  } catch (error, stack) {
    result['error'] = '$error\n$stack';
    rethrow;
  } finally {
    cleanup();
    result['fixture_removed'] = removed;
    write();
    stderr.writeln('[done] ${out.path}');
  }
  exit(0);
}

/// Commit and dirty state of the checkout whose lib/ is under test.
Future<Map<String, Object?>> _source() async {
  Future<String?> git(List<String> args) async {
    try {
      final r = await Process.run('git', args);
      return r.exitCode == 0 ? r.stdout.toString().trim() : null;
    } on ProcessException {
      return null;
    }
  }

  final head = await git(['rev-parse', 'HEAD']);
  final status = await git(['status', '--porcelain=v1']);
  final changed = status == null || status.isEmpty
      ? <String>[]
      : status.split('\n');
  return {
    'head': head,
    'dirty': status == null ? null : changed.isNotEmpty,
    'changed_paths': changed.take(50).toList(),
    'lib_dirty': changed.any((line) => line.contains('apps/client/lib/')),
  };
}

const _dropCache = r'''
import os, sys
n = 0
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        fd = os.open(os.path.join(d, f), os.O_RDONLY)
        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED); n += 1
        finally:
            os.close(fd)
print(n)
''';

void _sinkIsolate(SendPort reply) {
  final port = ReceivePort();
  reply.send(port.sendPort);
  port.listen((message) => reply.send(1));
}

/// Appends to probe files at spaced times from another isolate, so the write
/// timestamp is not delayed by a long synchronous engine pass. The spacing is
/// offset from the 2 s timer so probes do not always land on a pass boundary;
/// the timestamp is taken before the write starts.
Future<void> _probeIsolate(Map<String, Object?> args) async {
  final port = args['port'] as SendPort;
  final interval = Duration(milliseconds: args['interval_ms'] as int);
  var k = 0;
  for (final path in (args['paths'] as List).cast<String>()) {
    await Future<void>.delayed(interval + Duration(milliseconds: 613 * ++k));
    final file = File('${args['root']}/$path');
    final written = _now();
    file.writeAsStringSync(
      'probe $written\n',
      mode: FileMode.append,
      flush: true,
    );
    port.send({'path': path, 'written_us': written});
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
