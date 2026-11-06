// Decision #146 (flag SC-062; supersedes #145 and #144): when a pass reads
// every file because no stamp is trusted (#39) and no change watcher is
// reporting changes for the root (none, or it failed), the next scheduled
// pass of any kind (the interval, a local trigger, a cloud listing falling
// due) starts no sooner than min(10 min, max(interval, 9 x that pass's local
// scan)). The requests the app already makes bypass it (window shown,
// un-pause, user actions that ask for a pass), and every such pass still
// hashes every file. Any active watcher, event-driven or not, and trusted
// stamps mean no cap. The local-scan duration is a fake clock
// (debugLocalScanDuration), so a "slow" pass needs no slow disk.
import 'dart:async';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const files = 12;
const ext4 = 0xEF53;

void main() {
  late Directory fixture;
  late RootTree tree;
  late SyncEngine engine;
  late FakeCloud cloud;
  StreamController<Object?>? input;
  Future<void>? done;
  var opened = false;

  RootTree setUpTree(NativeRootFs fs, {required bool trusted}) {
    final parent = Directory('${fixture.path}/files')..createSync();
    final value = RootTree.setup(parent.path, 'cadence', fs);
    if (trusted) {
      final vm = Directory('${fixture.path}/vm')..createSync();
      File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('3000\n');
      File('${vm.path}/dirty_writeback_centisecs').writeAsStringSync('1500\n');
      File('${vm.path}/laptop_mode').writeAsStringSync('0\n');
      value
        ..debugFsMagic = ext4
        ..vmDirectory = vm.path;
    } else {
      // No writeback signal (the sysctls cannot be read): #39's untrusted case.
      value.vmDirectory = '${fixture.path}/no-vm';
    }
    for (var i = 0; i < files; i++) {
      File('${value.root.path}/Documents/f$i.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $i');
    }
    return value;
  }

  Future<SyncEngine> setUpEngine({
    required ChangeWatcherFactory watchers,
    required bool trusted,
    Duration? verification,
  }) async {
    final fs = NativeRootFs(null, 'Linux errno', verification);
    tree = setUpTree(fs, trusted: trusted);
    cloud = FakeCloud();
    engine = SyncEngine(
      Manifest(Directory('${fixture.path}/profile'))
        ..setSetting('retention', 'local'),
      tree,
      cloud,
      watchers: watchers,
    );
    opened = true;
    await engine.startWatching();
    return engine;
  }

  WorkerLoop start({
    Duration interval = const Duration(milliseconds: 200),
    Duration idle = const Duration(hours: 1),
  }) {
    final loop = WorkerLoop(
      engine,
      (_) {},
      interval: interval,
      schedule: RemoteSchedule(
        idle: idle,
        fast: idle,
        fastWindow: Duration.zero,
      ),
    );
    input = StreamController<Object?>();
    done = loop.run(input!.stream);
    return loop;
  }

  Future<void> until(bool Function() condition, {int seconds = 10}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Whole-root local scans so far (each reads every file; engine.passes
  /// counts only passes that reconcile).
  int scans() => (tree.native.meter.filesBy['scan'] ?? 0) ~/ files;

  /// Whole-root scans in [window] (the loop keeps running).
  Future<int> passesWithin(Duration window) async {
    final before = scans();
    await Future<void>.delayed(window);
    return scans() - before;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-cadence-');
    input = null;
    done = null;
    opened = false;
  });
  tearDown(() async {
    if (input != null) {
      input!.add({'action': 'stop'});
      await done;
      await input!.close();
    } else if (opened) {
      engine.close();
    }
    fixture.deleteSync(recursive: true);
  });

  group('untrusted stamps without a watcher (the stat scan)', () {
    test('a slow full-hash pass holds the next timer pass for 9 x its scan, '
        'and that pass still hashes every file', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(milliseconds: 400);
      final loop = start();
      await until(() => scans() >= 1 && cloud.files.length == files);
      expect(engine.lastPassReadWholeRoot, isTrue);
      expect(engine.lastPass!.filesHashedBy['scan'], files);
      expect(loop.nextBase(), const Duration(milliseconds: 3600));
      // Uncapped, a 200 ms interval would run about 10 passes in 2 s.
      final passes = scans();
      expect(await passesWithin(const Duration(seconds: 2)), 0);
      await until(() => scans() > passes, seconds: 6);
      expect(
        engine.lastPass!.filesHashedBy['scan'],
        files,
        reason: '#39: every file, every pass',
      );
    });

    test('a fast scan keeps the interval', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(milliseconds: 10);
      final loop = start();
      await until(() => scans() >= 1);
      expect(engine.lastPassReadWholeRoot, isTrue);
      expect(loop.nextBase(), const Duration(milliseconds: 200));
      expect(
        await passesWithin(const Duration(seconds: 2)),
        greaterThanOrEqualTo(3),
      );
    });

    test('an explicit retry, window shown and un-pause run a pass at once '
        'during the delay', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(seconds: 10);
      final loop = start();
      await until(() => scans() >= 1 && cloud.files.length == files);
      expect(loop.nextBase(), const Duration(seconds: 90));
      for (final command in [
        {'action': 'tick'},
        {'action': 'visible'},
        {'action': 'pause'},
        {'action': 'resume'},
      ]) {
        final passes = scans();
        input!.add(command);
        if (command['action'] == 'pause') {
          await until(() => loop.paused);
          continue;
        }
        await until(() => scans() > passes, seconds: 3);
        expect(engine.lastPass!.filesHashedBy['scan'], files);
      }
    });

    test('a cloud listing due inside the cap waits for it (decision #146): '
        'a 30 s scan holds a listing due at +30 s until +270 s', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(seconds: 30);
      final loop = start(idle: const Duration(seconds: 30));
      await until(() => scans() >= 1 && cloud.files.length == files);
      expect(loop.wholeRootCap, const Duration(seconds: 270));
      expect(loop.nextBase(), const Duration(seconds: 270));
      // The arithmetic of the next deadline, measured from the pass's end
      // (a fake clock): neither the listing due at +30 s nor a local
      // trigger at +30 s starts a pass before +270 s.
      for (final local in [null, const Duration(seconds: 30)]) {
        expect(
          WorkerLoop.scheduledDelay(
            base: loop.nextBase(),
            elapsed: Duration.zero,
            local: local,
            minGap: const Duration(milliseconds: 250),
            cap: loop.wholeRootCap,
          ),
          const Duration(seconds: 270),
        );
      }
      expect(
        WorkerLoop.scheduledDelay(
          base: loop.nextBase(),
          elapsed: const Duration(seconds: 200),
          local: Duration.zero,
          minGap: const Duration(milliseconds: 250),
          cap: loop.wholeRootCap,
        ),
        const Duration(seconds: 70),
      );
      // An explicit retry during the cap still runs at once, and lists.
      final passes = scans();
      input!.add({'action': 'tick'});
      await until(() => scans() > passes, seconds: 3);
      expect(engine.remoteListed, isTrue);
      expect(engine.lastPass!.filesHashedBy['scan'], files);
    });

    test('a 20-minute stalled scan caps at 10 minutes', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(minutes: 20);
      final loop = start(idle: const Duration(seconds: 30));
      await until(() => scans() >= 1 && cloud.files.length == files);
      expect(loop.wholeRootCap, const Duration(minutes: 10));
      expect(WorkerLoop.wholeRootCapCeiling, const Duration(minutes: 10));
      expect(loop.nextBase(), const Duration(minutes: 10));
      expect(
        WorkerLoop.scheduledDelay(
          base: loop.nextBase(),
          elapsed: Duration.zero,
          local: Duration.zero,
          minGap: const Duration(milliseconds: 250),
          cap: loop.wholeRootCap,
        ),
        const Duration(minutes: 10),
      );
    });

    test(
      'a local trigger inside the cap waits for it (the running loop)',
      () async {
        await setUpEngine(
          watchers: const UnwatchedChangeWatchers(),
          trusted: false,
        );
        engine.debugLocalScanDuration = (_) =>
            const Duration(milliseconds: 400);
        start();
        await until(() => scans() >= 1 && cloud.files.length == files);
        // Just after a pass: the cap (3.6 s) has most of its time left.
        final before = scans();
        await until(() => scans() > before, seconds: 6);
        final passes = scans();
        // What a watcher's change callback does: ask for a pass at the
        // interval (200 ms). The cap still holds it.
        engine.onLocalChange!();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(scans(), passes, reason: 'no pass inside the cap');
        await until(() => scans() > passes, seconds: 4);
      },
    );

    test('the same in the running loop, scaled: a 0.3 s scan holds a listing '
        'due at +0.3 s until +2.7 s, which then lists', () async {
      await setUpEngine(
        watchers: const UnwatchedChangeWatchers(),
        trusted: false,
      );
      engine.debugLocalScanDuration = (_) => const Duration(milliseconds: 300);
      start(idle: const Duration(milliseconds: 300));
      await until(() => scans() >= 1 && cloud.files.length == files);
      // From one whole-root scan to the next, at the loop's own cadence.
      var passes = scans();
      await until(() => scans() > passes);
      passes = scans();
      final seen = Stopwatch()..start();
      await until(() => scans() > passes, seconds: 6);
      expect(seen.elapsed, greaterThan(const Duration(milliseconds: 2500)));
      expect(engine.remoteListed, isTrue, reason: 'the held listing ran');
    });
  });

  group('an active watcher means no cap, event-driven or not', () {
    test('inotify with untrusted stamps (not event-driven): a new file '
        'uploads promptly', () async {
      await setUpEngine(watchers: const LinuxChangeWatchers(), trusted: false);
      expect(engine.watcher, isNotNull);
      (engine.watcher! as LocalWatcher)
        ..quiet = const Duration(milliseconds: 150)
        ..maxDelay = const Duration(seconds: 2);
      engine.debugLocalScanDuration = (_) => const Duration(seconds: 30);
      final loop = start(idle: const Duration(seconds: 30));
      await until(() => cloud.files.length == files);
      expect(engine.eventDriven, isFalse);
      expect(engine.lastPassReadWholeRoot, isFalse);
      expect(loop.wholeRootCap, Duration.zero);
      File('${tree.root.path}/Documents/new.txt').writeAsStringSync('new');
      final seen = Stopwatch()..start();
      await until(
        () => cloud.files.containsKey('Documents/new.txt'),
        seconds: 5,
      );
      expect(seen.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a watcher that fails mid-run: the stat-scan fallback is capped, '
        'and its restart waits for the cap', () async {
      await setUpEngine(watchers: const LinuxChangeWatchers(), trusted: false);
      engine.watchRestartDelay = const Duration(milliseconds: 500);
      engine.debugLocalScanDuration = (_) => const Duration(milliseconds: 400);
      final loop = start(idle: const Duration(hours: 1));
      await until(() => cloud.files.length == files);
      expect(loop.wholeRootCap, Duration.zero, reason: 'watching');
      final first = engine.watcher! as LocalWatcher;
      first.debugKill();
      await until(() => !first.active);
      // The first fallback pass (a full stat scan) reads the whole root.
      await until(() => engine.lastPassReadWholeRoot);
      expect(loop.wholeRootCap, const Duration(milliseconds: 3600));
      final passes = scans();
      final seen = Stopwatch()..start();
      // The restart is due 0.5 s after the failure; the cap holds it.
      await until(() => scans() > passes, seconds: 8);
      expect(seen.elapsed, greaterThan(const Duration(milliseconds: 3000)));
    });
  });

  test('watcher-driven (event-driven) hashing is unchanged', () async {
    await setUpEngine(
      watchers: const LinuxChangeWatchers(),
      trusted: false,
      verification: const Duration(minutes: 60),
    );
    expect(engine.watcher, isNotNull);
    engine.debugLocalScanDuration = (_) => const Duration(seconds: 10);
    final loop = start(idle: const Duration(seconds: 30));
    await until(
      () =>
          engine.passes >= 1 &&
          engine.lastPass != null &&
          cloud.files.length == files,
    );
    expect(engine.eventDriven, isTrue);
    expect(engine.lastPassReadWholeRoot, isFalse);
    expect(loop.wholeRootCap, Duration.zero);
    // A quiet event-driven pass waits for the listing, due within 30 s.
    expect(loop.nextBase(), lessThanOrEqualTo(const Duration(seconds: 30)));
  });

  group('trusted Linux stamps are unchanged', () {
    for (final watched in [false, true]) {
      test(watched ? 'with inotify' : 'without a watcher', () async {
        await setUpEngine(
          watchers: watched
              ? const LinuxChangeWatchers()
              : const UnwatchedChangeWatchers(),
          trusted: true,
        );
        engine.debugLocalScanDuration = (_) => const Duration(seconds: 10);
        final loop = start(idle: const Duration(seconds: 30));
        await until(
          () =>
              engine.passes >= 1 &&
              engine.lastPass != null &&
              cloud.files.length == files,
        );
        expect(tree.rootStampsTrusted, isTrue);
        expect(engine.lastPassReadWholeRoot, isFalse);
        expect(loop.wholeRootCap, Duration.zero);
        expect(loop.nextBase(), const Duration(milliseconds: 200));
      });
    }
  });
}
