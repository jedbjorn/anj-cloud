// Mac-side M2 tests (spec #31 acceptance row 6): the FSEvents watcher
// behind MacosChangeWatchers, driving the shared engine. The shared
// local_watch suites run on mac-test as well (tool/macos/check_macos.sh);
// this file adds what only FSEvents has: injected stream flags
// (MustScanSubDirs, the drop flags, no flag, RootChanged, Mount) proven by
// audit counters, suspend and periodic audits, the stream-failure fallback,
// the latency bound at production settings and a 5,000-file burst (watcher
// delivery gated; sync throughput recorded).
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_change_watchers.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';

import '../test/fakes.dart';

// FSEventStreamEventFlags (CoreServices FSEvents.h).
const mustScanSubDirs = 0x1;
const userDropped = 0x2;
const kernelDropped = 0x4;
const rootChanged = 0x20;
const mount = 0x40;

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;

  Future<void> open(WatcherSettings settings) async {
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(
      parent.path,
      'watch',
      const MacosPlatformAdapters().rootFilesystem(library),
    );
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local')
      ..verifyTracking = false;
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud)..watcherSettings = settings;
    await engine.startWatching();
  }

  setUp(() {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    fixture = Directory(
      Directory.systemTemp.createTempSync('anj-m2-').resolveSymbolicLinksSync(),
    );
  });
  tearDown(() {
    MacosChangeWatchers.debugFailStream = false;
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  LocalWatcher watcher() => engine.watcher! as LocalWatcher;
  File local(String path) => File('${tree.root.path}/$path');
  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  Future<void> pump(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) fail('condition not reached');
    }
  }

  Future<void> quiesce() async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      if (watcher().queued == 0 && engine.lastPass!.pathsVisited == 0) return;
    }
    fail('did not quiesce');
  }

  const fast = WatcherSettings(
    quiet: Duration(milliseconds: 150),
    maxDelay: Duration(seconds: 2),
  );

  // Each flag is proven by the audit it starts, read from the engine's and
  // the watcher's counters and the subtrees the watcher handed out, which do
  // not depend on what a pass hashed. (A hard-link write outside the root,
  // the Linux suites' "silent edit", is not silent here.)
  group('injected stream flags', () {
    setUp(() async {
      await open(fast);
      expect(engine.watcher, isNotNull, reason: 'APFS root: FSEvents stream');
      tree.ensureDirectory('Documents/sub/deeper');
      for (var i = 0; i < 5; i++) {
        local('Documents/sub/f$i.txt').writeAsStringSync('f $i');
      }
      local('Documents/other.txt').writeAsStringSync('other');
      await quiesce();
    });

    /// Injects [flags] at [path] and passes until [done].
    Future<void> inject(String path, int flags, bool Function() done) async {
      watcher().debugFsEvent(path, flags);
      await pump(done, timeout: const Duration(seconds: 10));
    }

    /// Injects [flags] at [path] and, without running a pass, collects the
    /// work the watcher hands out. On macOS #39's stamp fast path is off
    /// (writeback unknown), so every engine pass is a full stat scan and
    /// would absorb a subtree marker; the subtree claim is the watcher's.
    Future<WatchWork> injectTaken(String path, int flags) async {
      watcher().debugFsEvent(path, flags);
      final subtrees = <String>{}, paths = <String>{};
      var full = false;
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(end) && subtrees.isEmpty && !full) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final work = watcher().take();
        full = work.full;
        subtrees.addAll(work.subtrees);
        paths.addAll(work.paths);
      }
      if (full) watcher().beginFullAudit();
      return WatchWork(full: full, paths: paths, subtrees: subtrees);
    }

    test('MustScanSubDirs on a directory audits that subtree only', () async {
      final work = await injectTaken('Documents/sub', mustScanSubDirs);
      expect(work.full, isFalse, reason: 'the subtree, not the root');
      expect(work.subtrees, {'Documents/sub'});
    });

    test('a drop (MustScanSubDirs with User/KernelDropped) at the root runs '
        'the full overflow audit; beneath it, a subtree audit', () async {
      for (final drop in [userDropped, kernelDropped]) {
        final scans = engine.fullScans;
        final overflows = watcher().overflows;
        await inject(
          '',
          mustScanSubDirs | drop,
          () => engine.fullScans > scans,
        );
        expect(watcher().overflows, overflows + 1);
        expect(engine.fullScans, scans + 1);
        await quiesce();
        final work = await injectTaken('Documents', mustScanSubDirs | drop);
        expect(work.full, isFalse, reason: 'only Documents audited');
        expect(work.subtrees, {'Documents'});
      }
    });

    test('a flagless event (FlagNone) audits that directory', () async {
      final work = await injectTaken('Documents/sub', 0);
      expect(work.full, isFalse);
      expect(work.subtrees, {'Documents/sub'});
      final scans = engine.fullScans;
      // At the root: the full audit.
      await inject('', 0, () => engine.fullScans > scans);
      expect(engine.fullScans, scans + 1);
    });

    test('RootChanged runs the root self-audit', () async {
      final scans = engine.fullScans;
      final rootEvents = watcher().rootEvents;
      await inject('', rootChanged, () => engine.fullScans > scans);
      expect(watcher().rootEvents, rootEvents + 1);
      expect(engine.fullScans, scans + 1);
    });

    test('a mount beneath the root audits the mount point', () async {
      final work = await injectTaken('Documents/sub/deeper', mount);
      expect(work.full, isFalse);
      expect(work.subtrees, {'Documents/sub/deeper'});
    });

    test('a suspend (sleep clock jump) runs the full audit', () async {
      final scans = engine.fullScans;
      watcher().debugClockJump(const Duration(seconds: 30));
      await pump(() => engine.fullScans > scans);
      expect(watcher().suspends, 1);
      expect(engine.fullScans, scans + 1);
    });

    test('the periodic stat audit runs between events', () async {
      engine.statAuditInterval = Duration.zero;
      final scans = engine.fullScans;
      await engine.tick();
      expect(engine.fullScans, scans + 1);
    });

    // Not gated: which mechanism sees a write through a hard link outside
    // the root on this Mac (FSEvents, or the rehash of an untrusted stamp).
    test('diagnosis: a hard-link write outside the root', () async {
      final outside = File('${fixture.path}/outside-link');
      await Process.run('ln', [
        local('Documents/other.txt').path,
        outside.path,
      ]);
      await quiesce();
      final events = watcher().events;
      final queued = watcher().queued;
      outside.writeAsStringSync('through the link', flush: true);
      // No pass runs here: only the stream can change these counters.
      await Future<void>.delayed(const Duration(seconds: 1));
      final fromStream = watcher().events - events;
      // ignore: avoid_print
      print(
        'M2 diagnosis: hard-link write outside the root -> '
        '$fromStream FSEvents record(s), queued ${watcher().queued - queued}; '
        'stamps trusted here: '
        '${tree.trustsStamps(tree.native.identity(tree.fd).split(':').first, '')}'
        ' (writeback ${tree.writebackEnabled})',
      );
    });
  });

  test('a real root rename is reported as a root event', () async {
    await open(fast);
    local('r.txt').writeAsStringSync('r');
    await quiesce();
    final away = '${fixture.path}/files/away';
    final rootEvents = watcher().rootEvents;
    tree.root.renameSync(away);
    await pump(() => engine.message.startsWith('Paused'));
    expect(watcher().rootEvents, greaterThan(rootEvents));
    Directory(away).renameSync(tree.root.path);
    await pump(() => engine.message.startsWith('Reconciled'));
  });

  test(
    'when the stream cannot be created the per-pass stat scan stays',
    () async {
      MacosChangeWatchers.debugFailStream = true;
      await open(fast);
      expect(engine.watcher, isNull);
      expect(engine.watchUnavailable, isTrue);
      local('Documents/f.txt')
        ..parent.createSync()
        ..writeAsStringSync('f1');
      await engine.tick();
      expect(engine.lastPass!.localScan, 'full');
      expect(remote('Documents/f.txt'), 'f1');
      expect(engine.message, contains('Folder watching is unavailable'));
      local('Documents/f.txt').writeAsStringSync('f2');
      await engine.tick();
      expect(remote('Documents/f.txt'), 'f2');
      expect(engine.fullScans, 2);
    },
  );

  test('at production settings a change reaches a pass within quiet + '
      'maxDelay, also under continuous writes', () async {
    const production = WatcherSettings();
    final bound = production.quiet + production.maxDelay;
    await open(production);
    tree.ensureDirectory('Documents');
    await engine.tick(); // The startup audit.
    final timings = <String, Duration>{};
    // One write, then quiet.
    var started = DateTime.now();
    local('Documents/one.txt').writeAsStringSync('one');
    await pump(() => remote('Documents/one.txt') == 'one');
    timings['single write'] = DateTime.now().difference(started);
    // A file rewritten every 300 ms never goes quiet: the maximum delay.
    started = DateTime.now();
    var n = 0;
    var first = Duration.zero;
    while (DateTime.now().difference(started) < const Duration(seconds: 13)) {
      local('Documents/busy.txt').writeAsStringSync('busy ${n++}');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.tick();
      if (first == Duration.zero && remote('Documents/busy.txt') != null) {
        first = DateTime.now().difference(started);
      }
    }
    timings['continuous writes, first upload'] = first;
    // ignore: avoid_print
    print(
      'M2 latency at quiet ${production.quiet}, maxDelay '
      '${production.maxDelay}: $timings',
    );
    expect(timings['single write']!, lessThan(bound));
    expect(first, greaterThan(Duration.zero), reason: 'uploaded while busy');
    expect(first, lessThan(bound + const Duration(milliseconds: 300)));
  }, timeout: const Timeout(Duration(minutes: 1)));

  // Row 6's claim is watcher delivery: every create of a 5,000-file burst
  // reaches the engine's work (a queued path, a subtree covering it, or a
  // full audit) within quiet + maxDelay, with nothing lost. No pass runs
  // during that part, so it measures the stream and the queue alone.
  // End-to-end sync throughput is then recorded for a bounded time and not
  // gated: each path costs a manifest commit with F_FULLFSYNC (#129).
  test('a 5,000-file burst: every create reaches the queue within quiet + '
      'maxDelay; sync throughput recorded', () async {
    const production = WatcherSettings();
    final bound = production.quiet + production.maxDelay;
    await open(production);
    tree.ensureDirectory('Documents/burst');
    await engine.tick(); // The startup audit watches Documents/burst.
    final created = <String>[];
    final started = DateTime.now();
    for (var d = 0; d < 50; d++) {
      final dir = Directory('${tree.root.path}/Documents/burst/d$d')
        ..createSync();
      for (var f = 0; f < 100; f++) {
        File('${dir.path}/f$f.txt').writeAsStringSync('burst $d $f');
        created.add('Documents/burst/d$d/f$f.txt');
      }
    }
    final written = DateTime.now();
    final paths = <String>{};
    final subtrees = <String>{};
    var full = false;
    bool covered(String path) {
      if (full || paths.contains(path)) return true;
      for (var a = path; a.contains('/');) {
        a = a.substring(0, a.lastIndexOf('/'));
        if (subtrees.contains(a)) return true;
      }
      return false;
    }

    // Each change is bounded from its own time; the end of the burst is
    // later than every change, so this deadline is the lenient one.
    final deadline = written.add(bound);
    var missing = created.length;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final work = watcher().take();
      if (work.full) {
        full = true;
        watcher().beginFullAudit();
      }
      paths.addAll(work.paths);
      subtrees.addAll(work.subtrees);
      missing = created.where((p) => !covered(p)).length;
      if (missing == 0) break;
    }
    final delivered = DateTime.now().difference(written);
    // Throughput, not gated, from a 200-file sample: on macOS every pass
    // is a full stat scan that hashes every file (#39 fast path off) and
    // each path costs a manifest commit with F_FULLFSYNC (#129), so one
    // pass over 5,000 paths takes minutes. The burst is removed first.
    Directory('${tree.root.path}/Documents/burst').deleteSync(recursive: true);
    watcher().beginFullAudit();
    await engine.tick();
    tree.ensureDirectory('Documents/sample');
    for (var i = 0; i < 200; i++) {
      local('Documents/sample/s$i.txt').writeAsStringSync('sample $i');
    }
    final syncStart = DateTime.now();
    var uploaded = 0;
    while (uploaded < 200 &&
        DateTime.now().difference(syncStart) < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      uploaded = cloud.files.keys
          .where((k) => k.startsWith('Documents/sample/'))
          .length;
    }
    final syncFor = DateTime.now().difference(syncStart);
    final perPath = uploaded == 0 ? null : syncFor.inMilliseconds / uploaded;
    // ignore: avoid_print
    print(
      'M2 burst: 5000 files written in ${written.difference(started)}; '
      'delivery: all covered ${missing == 0} after $delivered (bound '
      '$bound), ${paths.length} paths, ${subtrees.length} subtrees, full '
      '$full, overflows ${watcher().overflows}, collapses '
      '${watcher().collapses}; sync sample: $uploaded of 200 uploaded in '
      '$syncFor (${perPath?.toStringAsFixed(1)} ms per path)',
    );
    expect(missing, 0, reason: 'every create reached the engine work');
    expect(delivered, lessThan(bound));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
