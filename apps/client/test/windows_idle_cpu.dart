// Spec #32 "File Watching" on W10C-Testing: idle CPU of the background sync
// worker with the ReadDirectoryChangesW watcher against the per-pass stat
// scan it replaces. One mode per test file, and flutter test runs each file
// in its own process, so GetProcessTimes measures only that mode;
// tool/windows/idle_cpu.ps1 runs both files at once (--concurrency=2),
// unelevated, with ANJ_WW_IDLE_SECONDS set (each file skips without it).
//
// WorkerLoop over the real SyncEngine, RootTree and anj_rootfs.dll
// (ANJ_ROOTFS_LIBRARY) with an in-memory cloud and a 1,000-file root: what
// runs while the app's window is closed, without the app's UI. Prints one
// "WW idle" line; the comparison is the evidence, not a pass threshold.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

final _kernel = DynamicLibrary.open('kernel32.dll');
final _getProcessTimes = _kernel
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Int64>,
      ),
      int Function(
        int,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Int64>,
        Pointer<Int64>,
      )
    >('GetProcessTimes');
final _currentProcess = _kernel
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

/// User + kernel CPU of this process, in milliseconds.
int cpuMs() {
  final times = calloc<Int64>(4);
  try {
    _getProcessTimes(_currentProcess(), times, times + 1, times + 2, times + 3);
    return (times[2] + times[3]) ~/ 10000;
  } finally {
    calloc.free(times);
  }
}

/// Files in the idle root.
const idleFiles = 1000;

/// The idle seconds per mode, or null (the files skip).
int? idleSeconds() =>
    int.tryParse(Platform.environment['ANJ_WW_IDLE_SECONDS'] ?? '');

/// One mode's measurement; returns the files synced.
Future<int> idleCpu(String mode, int seconds) async {
  final ChangeWatcherFactory watchers = switch (mode) {
    'watcher' => const WindowsChangeWatchers(),
    'stat-scan' => const UnwatchedChangeWatchers(),
    _ => throw ArgumentError('mode: watcher or stat-scan'),
  };
  final work = Directory.systemTemp.createTempSync('anj-ww-idle-$mode-');
  final tree = RootTree.setup(work.path, 'idle', windowsRootFilesystem());
  for (var d = 0; d < 10; d++) {
    for (var f = 0; f < 100; f++) {
      File(p.join(tree.root.path, 'Documents', 'd$d', 'f$f.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $d/$f');
    }
  }
  final store = Manifest(Directory(p.join(work.path, 'profile')))
    ..setSetting('retention', 'local');
  final cloud = FakeCloud();
  final engine = SyncEngine(store, tree, cloud, watchers: watchers);
  await engine.startWatching();
  final input = StreamController<Object?>();
  final done = WorkerLoop(engine, (_) {}).run(input.stream);
  // The first sync, then calm: measured only from a pass that planned
  // nothing, so neither window holds sync work. (Without the watcher a pass
  // on NTFS still reads every file: that is the baseline's idle cost.)
  final began = DateTime.now();
  final settle = began.add(const Duration(minutes: 10));
  bool calm() {
    final pass = engine.lastPass;
    return cloud.files.length >= idleFiles &&
        pass != null &&
        pass.candidates == 0;
  }

  while (!calm() && DateTime.now().isBefore(settle)) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  // ignore: avoid_print
  print(
    'WW idle mode=$mode settled=${calm()} after '
    '${DateTime.now().difference(began).inSeconds} s, synced ${cloud.files.length}',
  );
  if (!calm()) {
    // The worker closes the engine as it stops (WorkerLoop.run).
    input.add({'action': 'stop'});
    await done;
    await input.close();
    return cloud.files.length;
  }
  // Test-only (decision #146 on the seat): from here every local scan is
  // recorded as ANJ_WW_IDLE_SCAN_MS long, so the whole-root cap bites
  // without a root large enough to need it.
  final fakeScan = int.tryParse(
    Platform.environment['ANJ_WW_IDLE_SCAN_MS'] ?? '',
  );
  if (fakeScan != null && fakeScan > 0) {
    engine.debugLocalScanDuration = (_) => Duration(milliseconds: fakeScan);
  }
  var passes = 0, hashed = 0, statted = 0;
  var last = engine.lastPass;
  final scans0 = engine.fullScans;
  final verifications0 = engine.fullVerifications;
  var shownScans = scans0;
  final cpu0 = cpuMs();
  final measured = DateTime.now();
  final end = measured.add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!identical(engine.lastPass, last)) {
      passes++;
      last = engine.lastPass;
      hashed += last?.filesHashed ?? 0;
      statted += last?.pathsVisited ?? 0;
      if ((last?.filesHashed ?? 0) > 0 || engine.fullScans != shownScans) {
        shownScans = engine.fullScans;
        final w = engine.watcher;
        final lw = w is LocalWatcher ? w : null;
        // ignore: avoid_print
        print(
          'WW pass mode=$mode t+${DateTime.now().difference(measured).inSeconds}s '
          'local=${last?.localScan} remoteAudit=${last?.full} '
          'listed=${engine.remoteListed} '
          'hashedBy=${last?.filesHashedBy} statted=${last?.pathsStatted} '
          'fullScans=${engine.fullScans} verifications=${engine.fullVerifications} '
          'watcher=${w?.active} failure=${w?.failure} overflows=${lw?.overflows} '
          'rootEvents=${lw?.rootEvents}',
        );
      }
    }
  }
  final cpu = cpuMs() - cpu0;
  // ignore: avoid_print
  print(
    'WW idle mode=$mode seconds=$seconds cpu_ms=$cpu '
    'cpu_pct=${(cpu / (seconds * 1000) * 100).toStringAsFixed(3)} passes=$passes '
    'files_hashed=$hashed paths_visited=$statted '
    'full_scans=${engine.fullScans - scans0} '
    'full_verifications=${engine.fullVerifications - verifications0} '
    'faked_scan_ms=${fakeScan ?? 0} '
    'watcher=${engine.watcher?.active ?? false} synced=${cloud.files.length}',
  );
  input.add({'action': 'stop'});
  await done;
  await input.close();
  final synced = cloud.files.length;
  try {
    work.deleteSync(recursive: true);
  } on FileSystemException {
    // Left for the run's cleanup.
  }
  return synced;
}
