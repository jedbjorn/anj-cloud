// Decisions #135 (macOS) and #130 (3) (Android): event-driven hashing.
// Without trusted stamps, a platform with a verification interval and a
// working watcher hashes only the paths the watcher reported; a full
// verification pass hashes every file at start, after lost events, after a
// watcher restart and at the interval. Runs on the VM host over the Linux build of
// the anj_* ABI and inotify, with writeback off and an interval set (the
// macOS adapter passes 60 minutes); the FSEvents run is on mac-test
// (test_macos/fsevents_watch_macos_test.dart). Adapted from PR #60's suite,
// which Android keeps once it adopts this shared switch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// The shared binding with a verification interval, as the macOS adapter
/// constructs it, but over the Linux library.
class _ShortVerification extends NativeRootFs {
  _ShortVerification(this.interval)
    : super(Platform.environment['ANJ_ROOTFS_LIBRARY']);
  Duration interval;
  @override
  Duration? get fullVerificationInterval => interval;
}

/// A pass that does its work and then throws (after lastPass is set).
class _Throwing extends SyncEngine {
  _Throwing(super.manifest, super.tree, super.cloud)
    : super(watchers: const LinuxChangeWatchers());
  @override
  Future<void> tick({
    Future<bool> Function()? between,
    RemotePolicy remote = RemotePolicy.always,
  }) async {
    await super.tick(between: between, remote: remote);
    throw const FileSystemException('injected pass failure');
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  late _ShortVerification fs;
  var closed = false;

  File local(String path) => File('${tree.root.path}/$path');
  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  LocalWatcher watcher() => engine.watcher! as LocalWatcher;

  Future<void> pump(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) fail('condition not reached');
    }
  }

  /// Ticks until the watcher holds nothing and a pass hashes nothing.
  Future<void> quiesce() async {
    var calm = 0;
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      calm = watcher().queued == 0 && engine.lastPass!.filesHashed == 0
          ? calm + 1
          : 0;
      if (calm >= 4) return;
    }
    fail('did not quiesce');
  }

  Future<SyncEngine> open(SyncEngine Function() create) async {
    final value = create();
    await value.startWatching();
    expect(value.watcher, isNotNull);
    (value.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
    return value;
  }

  setUp(() async {
    closed = false;
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-event-hash-')
          .resolveSymbolicLinksSync(),
    );
    fs = _ShortVerification(const Duration(minutes: 60));
    // No writeback signal (the sysctls cannot be read), as on macOS.
    tree = RootTree.setup(fixture.path, 'events', fs)
      ..vmDirectory = '${fixture.path}/no-vm';
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    for (var i = 0; i < 20; i++) {
      local('Documents/f$i.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $i');
    }
    engine = await open(
      () =>
          SyncEngine(store, tree, cloud, watchers: const LinuxChangeWatchers()),
    );
  });

  tearDown(() {
    if (!closed) engine.close();
    fixture.deleteSync(recursive: true);
  });

  test(
    'the first pass verifies every file, idle passes hash nothing',
    () async {
      await engine.tick();
      expect(engine.eventDriven, isTrue);
      expect(engine.fullVerifications, 1);
      expect(engine.lastPass!.filesHashedBy['scan'], 20);
      await quiesce();
      for (var i = 0; i < 3; i++) {
        await engine.tick();
        expect(engine.lastPass!.filesHashed, 0);
        expect(engine.lastPass!.localScan, 'partial');
      }
      expect(engine.fullVerifications, 1);
      expect(cloud.uploads, 20);
    },
  );

  test(
    'an ordinary pass hashes only the reported paths and new entries',
    () async {
      await engine.tick();
      await quiesce();
      local('Documents/f3.txt').writeAsStringSync('changed');
      local('Documents/new.txt').writeAsStringSync('new');
      Directory('${tree.root.path}/Documents/Sub').createSync();
      local('Documents/Sub/inner.txt').writeAsStringSync('inner');
      var hashed = 0;
      await pump(() {
        hashed += engine.lastPass!.filesHashedBy['scan'] ?? 0;
        return remote('Documents/f3.txt') == 'changed' &&
            remote('Documents/new.txt') == 'new' &&
            remote('Documents/Sub/inner.txt') == 'inner';
      });
      // Three changed files, each read at most twice (event and own upload
      // check), never the other nineteen.
      expect(hashed, inInclusiveRange(3, 6));
      expect(engine.fullVerifications, 1);
    },
  );

  test('a missed change is caught by the next full verification', () async {
    await engine.tick();
    await quiesce();
    // The watcher misses this write (its event is dropped, as a shared-mmap
    // write would never produce one).
    local('Documents/f5.txt').writeAsStringSync('missed');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    watcher().take();
    watcher().take();
    for (var i = 0; i < 3; i++) {
      await engine.tick();
    }
    expect(remote('Documents/f5.txt'), 'file 5', reason: 'not seen yet');
    // At the interval the full pass reads every file and finds it.
    fs.interval = const Duration(milliseconds: 1);
    await engine.tick();
    expect(engine.fullVerifications, 2);
    expect(engine.lastPass!.filesHashedBy['scan'], greaterThanOrEqualTo(20));
    await pump(() => remote('Documents/f5.txt') == 'missed');
  });

  test('the 5-minute stat audit finds a missed change and reads only it '
      '(decision #137 (3))', () async {
    await engine.tick();
    await quiesce();
    local('Documents/f8.txt').writeAsStringSync('missed, new size');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    watcher().take();
    watcher().take();
    await engine.tick();
    expect(remote('Documents/f8.txt'), 'file 8', reason: 'not seen yet');
    final verifications = engine.fullVerifications;
    final scans = engine.fullScans;
    engine.statAuditInterval = Duration.zero;
    await engine.tick();
    engine.statAuditInterval = const Duration(minutes: 5);
    expect(engine.fullScans, scans + 1, reason: 'a stat audit ran');
    expect(
      engine.fullVerifications,
      verifications,
      reason: 'not a verification',
    );
    expect(engine.lastPass!.filesHashedBy['scan'], 1, reason: 'only f8 read');
    await pump(() => remote('Documents/f8.txt') == 'missed, new size');
  });

  test(
    'a hint naming an unwatched folder re-stats beneath it and reads no '
    'unchanged file (PR #84 review: Windows watches only the root)',
    () async {
      tree.ensureDirectory('Documents/limited/deeper');
      for (var i = 0; i < 5; i++) {
        local('Documents/limited/deeper/g$i.txt').writeAsStringSync('g $i');
      }
      watcher().debugFailAdds('Documents/limited');
      await engine.tick();
      await quiesce();
      expect(watcher().watching('Documents/limited'), isFalse);
      expect(remote('Documents/limited/deeper/g4.txt'), 'g 4');
      final verifications = engine.fullVerifications;
      final scans = engine.fullScans;
      watcher().enqueue('Documents/limited');
      var read = 0;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
        read += engine.lastPass!.filesHashedBy['scan'] ?? 0;
      }
      expect(watcher().queued, 0, reason: 'the hint was taken');
      expect(read, 0, reason: 'no unchanged file beneath the folder is read');
      expect(engine.fullScans, scans);
      expect(engine.fullVerifications, verifications);
      // A changed file beneath it is still found by its stamp.
      local('Documents/limited/deeper/g2.txt').writeAsStringSync('g 2, edited');
      watcher().enqueue('Documents/limited');
      await pump(
        () => remote('Documents/limited/deeper/g2.txt') == 'g 2, edited',
      );
      watcher().debugFailAdds(null);
    },
  );

  test('requestFullVerification asks for a full verification', () async {
    await engine.tick();
    await quiesce();
    local('Documents/f6.txt').writeAsStringSync('missed');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    watcher().take();
    watcher().take();
    expect(engine.nextLocalDeadline(), isNot(Duration.zero));
    engine.requestFullVerification();
    expect(engine.nextLocalDeadline(), Duration.zero);
    await engine.tick();
    expect(engine.fullVerifications, 2);
    await pump(() => remote('Documents/f6.txt') == 'missed');
    await engine.tick();
    expect(engine.fullVerifications, 2, reason: 'one request, one pass');
  });

  test('a watcher overflow triggers a full verification', () async {
    await engine.tick();
    await quiesce();
    watcher().native.watchDebugInject(watcher().handle, -1, inQueueOverflow);
    await pump(() => engine.fullVerifications == 2);
    expect(engine.lastPass!.filesHashedBy['scan'], greaterThanOrEqualTo(20));
  });

  test(
    'a root self event (RootChanged on macOS) verifies every file',
    () async {
      await engine.tick();
      await quiesce();
      final root = watcher().debugWatchDescriptor('')!;
      watcher().handleRecords([root, 0x800, 0, '']); // IN_MOVE_SELF
      await pump(() => engine.fullVerifications == 2);
      expect(engine.lastPass!.filesHashedBy['scan'], greaterThanOrEqualTo(20));
    },
  );

  test('a suspend (wake from sleep) verifies every file', () async {
    await engine.tick();
    await quiesce();
    watcher().debugClockJump(const Duration(seconds: 30));
    await pump(() => engine.fullVerifications == 2);
    expect(watcher().suspends, 1);
  });

  test('a dead watcher: every pass is full; the restart verifies once, then '
      'passes are event-driven again', () async {
    await engine.tick();
    await quiesce();
    engine
      ..watchRestartDelay = const Duration(milliseconds: 300)
      ..watchRestartLimit = 1;
    final first = watcher();
    first.debugKill();
    for (var i = 0; first.active && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(engine.eventDriven, isFalse);
    await engine.tick();
    expect(engine.lastPass!.localScan, 'full');
    expect(engine.lastPass!.filesHashedBy['scan'], 20);
    final verifications = engine.fullVerifications;
    // The pass that restarts the watcher is its full verification.
    await pump(() => engine.watcher != first && engine.watcher!.active);
    expect(engine.fullVerifications, verifications + 1);
    expect(engine.lastPass!.localScan, 'full');
    expect(engine.eventDriven, isTrue);
    await quiesce();
    await engine.tick();
    expect(engine.lastPass!.filesHashed, 0);
  });

  test('a paused check reads no file content and finds the change', () async {
    await engine.tick();
    await quiesce();
    local('Documents/f7.txt').writeAsStringSync('edited while paused');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final reads = fs.meter.files;
    expect(await engine.observePaused(), greaterThanOrEqualTo(1));
    expect(fs.meter.files, reads, reason: 'stat-only while paused');
    await pump(() => remote('Documents/f7.txt') == 'edited while paused');
  });

  test('Linux keeps hashing every file every pass without writeback', () async {
    engine.close();
    closed = true;
    final linuxFs = NativeRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']);
    final linuxTree = RootTree(tree.root, tree.staging, linuxFs)
      ..vmDirectory = '${fixture.path}/no-vm';
    final linux = await open(
      () => SyncEngine(
        Manifest(Directory('${fixture.path}/profile')),
        linuxTree,
        cloud,
        watchers: const LinuxChangeWatchers(),
      ),
    );
    try {
      for (var i = 0; i < 3; i++) {
        await linux.tick();
        expect(linux.eventDriven, isFalse);
        expect(linux.lastPass!.filesHashedBy['scan'], 20);
        expect(linux.lastPass!.localScan, 'full');
      }
      expect(linux.fullVerifications, 0);
    } finally {
      linux.close();
    }
  });

  test(
    'no back-to-back timer passes while nothing changed',
    () async {
      engine.close();
      closed = true;
      Future<int> passesIn(SyncEngine value, Duration span) async {
        final input = StreamController<Object?>();
        final loop = WorkerLoop(
          value,
          (_) {},
          interval: const Duration(milliseconds: 100),
          schedule: RemoteSchedule(idle: const Duration(seconds: 30)),
        );
        final done = loop.run(input.stream);
        await Future<void>.delayed(const Duration(seconds: 1));
        // Each pass replaces lastPass; sample often enough to see every one.
        var count = 0;
        var last = value.lastPass;
        final end = DateTime.now().add(span);
        while (DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (!identical(value.lastPass, last)) {
            count++;
            last = value.lastPass;
          }
        }
        input.add({'action': 'stop'});
        await done;
        await input.close();
        return count;
      }

      final events = await open(
        () => SyncEngine(
          Manifest(Directory('${fixture.path}/profile')),
          RootTree(tree.root, tree.staging, fs)
            ..vmDirectory = '${fixture.path}/no-vm',
          cloud,
          watchers: const LinuxChangeWatchers(),
        ),
      );
      final idle = await passesIn(events, const Duration(seconds: 2));
      expect(idle, lessThanOrEqualTo(1), reason: 'quiet: wait for the listing');

      // A pass that throws is never quiet (PR #68 review): the timer stays.
      final failing = await open(
        () => _Throwing(
          Manifest(Directory('${fixture.path}/profile')),
          RootTree(tree.root, tree.staging, fs)
            ..vmDirectory = '${fixture.path}/no-vm',
          cloud,
        ),
      );
      final retries = await passesIn(failing, const Duration(seconds: 2));
      expect(retries, greaterThanOrEqualTo(5), reason: 'failed passes retry');

      final linuxTree = RootTree(
        tree.root,
        tree.staging,
        NativeRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']),
      )..vmDirectory = '${fixture.path}/no-vm';
      final linux = await open(
        () => SyncEngine(
          Manifest(Directory('${fixture.path}/profile')),
          linuxTree,
          cloud,
          watchers: const LinuxChangeWatchers(),
        ),
      );
      final linuxPasses = await passesIn(linux, const Duration(seconds: 2));
      expect(linuxPasses, greaterThanOrEqualTo(5), reason: 'Linux unchanged');
    },
    // The idle-pass bound is calibrated on inotify (see the header). Over
    // FSEvents, mac-test counted 2 passes in the 2 s window (M7 run 1,
    // 2026-11-04); the macOS idle cost is acceptance row 12 on mac-test.
    skip: linuxOnly(
      'the idle-pass count is calibrated on inotify; '
      'macOS idle cost is spec #31 row 12 on mac-test',
    ),
  );
}
