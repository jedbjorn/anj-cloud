import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dbus_harness.dart' show eventually;
import 'fakes.dart';
import 'test_platform.dart';

/// Counts every request that would reach the network.
class CountingCloud extends FakeCloud {
  int snapshots = 0;
  int requests = 0;
  final snapshotTimes = <DateTime>[];

  @override
  Future<List<RemoteItem>> snapshot() {
    snapshots++;
    requests++;
    snapshotTimes.add(DateTime.now());
    return super.snapshot();
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    requests++;
    return super.download(path, target, etag: etag);
  }

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    requests++;
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> mkdir(String path) {
    requests++;
    return super.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    requests++;
    return super.deleteFile(path, etag: etag);
  }

  @override
  Future<AddedPage?> addedSince(int after) {
    requests++;
    return super.addedSince(after);
  }
}

/// An upload that never completes until the client is closed (aborted).
class BlockingCloud extends CountingCloud {
  final started = Completer<void>();
  final _abort = Completer<void>();
  bool closed = false;

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    requests++;
    if (!started.isCompleted) started.complete();
    await _abort.future;
    throw const CloudFailure('connection closed during transfer');
  }

  @override
  void close() {
    closed = true;
    if (!_abort.isCompleted) _abort.complete();
  }
}

void main() {
  late Directory fixture;
  late Directory profile;
  late Directory parent;
  late RootTree tree;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-sync-lifecycle-');
    profile = Directory('${fixture.path}/profile');
    parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'life', NativeRootFs());
    final store = Manifest(profile)..setSetting('retention', 'local');
    store.close();
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  File local(String path) => File('${tree.root.path}/$path');
  File wal() => File('${profile.path}/manifest.sqlite-wal');

  /// A worker loop over a fresh manifest/tree, as each process start does.
  ({
    WorkerLoop loop,
    Future<void> done,
    StreamController<Object?> input,
    List<Map> events,
    PausableCloud gate,
  })
  startLoop(
    FakeCloud cloud, {
    RemoteSchedule? schedule,
    Duration interval = const Duration(milliseconds: 40),
    Duration pausedInterval = const Duration(milliseconds: 40),
    Duration abortGrace = const Duration(seconds: 5),
  }) {
    final store = Manifest(profile);
    final freshTree = RootTree(tree.root, tree.staging, NativeRootFs());
    final gate = PausableCloud(cloud);
    final engine = SyncEngine(store, freshTree, gate);
    final events = <Map>[];
    final input = StreamController<Object?>();
    final loop = WorkerLoop(
      engine,
      (event) => events.add(event as Map),
      interval: interval,
      schedule: schedule,
      gate: gate,
      pausedInterval: pausedInterval,
      abortGrace: abortGrace,
    );
    return (
      loop: loop,
      done: loop.run(input.stream),
      input: input,
      events: events,
      gate: gate,
    );
  }

  Map? lastState(List<Map> events) =>
      events.lastWhere((e) => e['event'] == 'state', orElse: () => {});

  group('RemoteSchedule (fake clock)', () {
    late Duration now;
    RemoteSchedule schedule() =>
        RemoteSchedule(clock: () => now, random: Random(7));
    setUp(() => now = Duration.zero);

    test('idle cadence is about 30 s; local work lists early', () {
      final s = schedule();
      expect(s.policy(), RemotePolicy.always, reason: 'first pass lists');
      s.completed(listed: true, failed: false);
      now = const Duration(seconds: 29);
      expect(s.policy(), RemotePolicy.ifLocalWork);
      now = const Duration(seconds: 30);
      expect(s.policy(), RemotePolicy.always);
      s.completed(listed: true, failed: false);
      expect(s.untilDue, const Duration(seconds: 30));
      // A local-only pass leaves the due time alone.
      now += const Duration(seconds: 2);
      s.completed(listed: false, failed: false);
      expect(s.untilDue, const Duration(seconds: 28));
    });

    test('window shown or resume lists immediately', () {
      final s = schedule()..completed(listed: true, failed: false);
      now = const Duration(seconds: 3);
      expect(s.policy(), RemotePolicy.ifLocalWork);
      s.requestNow();
      expect(s.policy(), RemotePolicy.always);
    });

    test('own mutations open a short faster window', () {
      final s = schedule()..completed(listed: true, failed: false);
      s.mutated();
      expect(s.untilDue, const Duration(seconds: 3));
      for (var i = 0; i < 5; i++) {
        now += const Duration(seconds: 3);
        expect(s.policy(), RemotePolicy.always);
        s.completed(listed: true, failed: false);
        expect(s.untilDue, const Duration(seconds: 3));
      }
      now += const Duration(seconds: 30);
      s.completed(listed: true, failed: false);
      expect(s.untilDue, const Duration(seconds: 30));
    });

    test('offline: exponential backoff with jitter, capped, no early '
        'listing for local work', () {
      final s = schedule();
      final delays = <Duration>[];
      for (var i = 0; i < 9; i++) {
        s.completed(listed: false, failed: true);
        delays.add(s.untilDue);
        expect(s.policy(), RemotePolicy.never);
        now += s.untilDue;
        expect(s.policy(), RemotePolicy.always);
      }
      expect(s.offline, isTrue);
      for (var i = 0; i < delays.length; i++) {
        final nominal = min(5 * (1 << i), 300);
        expect(delays[i].inMilliseconds, greaterThanOrEqualTo(nominal * 750));
        expect(delays[i].inMilliseconds, lessThanOrEqualTo(nominal * 1250));
      }
      // Window shown while offline retries at once; success resets.
      s.completed(listed: false, failed: true);
      s.requestNow();
      expect(s.policy(), RemotePolicy.always);
      s.completed(listed: true, failed: false);
      expect(s.offline, isFalse);
      expect(s.untilDue, const Duration(seconds: 30));
    });

    test('jitter spreads retries of many clients', () {
      final values = <int>{};
      for (var seed = 0; seed < 20; seed++) {
        final s = RemoteSchedule(clock: () => now, random: Random(seed))
          ..completed(listed: false, failed: true);
        values.add(s.untilDue.inMilliseconds);
      }
      expect(values.length, greaterThan(10));
    });
  });

  test('PausableCloud refuses every request while paused', () async {
    final inner = CountingCloud();
    final gate = PausableCloud(inner)..paused = true;
    final file = File('${fixture.path}/x')..writeAsStringSync('x');
    await expectLater(gate.snapshot(), throwsA(isA<CloudFailure>()));
    expect(
      () => gate.download('a', file, etag: '"1"'),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => gate.upload('a', file, etag: null),
      throwsA(isA<CloudFailure>()),
    );
    expect(() => gate.mkdir('a'), throwsA(isA<CloudFailure>()));
    expect(
      () => gate.deleteFile('a', etag: '"1"'),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => gate.deleteFolder('a', versions: const {}),
      throwsA(isA<CloudFailure>()),
    );
    // Added times are file metadata: refused while paused too (#53).
    await expectLater(gate.addedSince(0), throwsA(isA<CloudFailure>()));
    expect(inner.requests, 0);
    expect(gate.refused, 7);
    gate.paused = false;
    expect(await gate.snapshot(), isEmpty);
    expect(inner.requests, 1);
  });

  group('pause', () {
    test('persists across restart; nothing reaches the network or the root '
        'while paused; resume syncs local and remote edits', () async {
      final cloud = CountingCloud();
      local('before.txt').writeAsStringSync('synced before pause');
      var run = startLoop(cloud);
      await eventually(() => cloud.files.containsKey('before.txt'));
      run.input.add({'action': 'pause'});
      await eventually(() => lastState(run.events)?['paused'] == true);
      expect(lastState(run.events)!['status'], 'paused');
      final requests = cloud.requests;
      local('edited.txt').writeAsStringSync('written while paused');
      local('before.txt').deleteSync();
      cloud.put('remote.txt', 'remote while paused');
      await eventually(
        () => (lastState(run.events)!['message'] as String).contains(
          '2 local changes',
        ),
      );
      // Commands that change the root at once are refused while paused.
      run.input.add({
        'action': 'createFolder',
        'request': 'r1',
        'parent': '',
        'name': 'New',
        'value': 'local',
      });
      await eventually(
        () => run.events.any((e) => e['event'] == 'folderCreateFailed'),
      );
      expect(
        run.events.firstWhere(
          (e) => e['event'] == 'folderCreateFailed',
        )['message'],
        contains('paused'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
      expect(cloud.requests, requests, reason: 'no network while paused');
      expect(run.gate.refused, 0, reason: 'not even attempted');
      expect(local('remote.txt').existsSync(), isFalse);
      expect(cloud.files.containsKey('before.txt'), isTrue);
      expect(wal().existsSync(), isFalse, reason: 'clean stop checkpoints');

      // Restart: the pause is read from the profile.
      run = startLoop(cloud);
      await eventually(() => lastState(run.events)?['paused'] == true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(cloud.requests, requests);
      expect(local('remote.txt').existsSync(), isFalse);

      run.input.add({'action': 'resume'});
      await eventually(
        () =>
            cloud.files.containsKey('edited.txt') &&
            !cloud.files.containsKey('before.txt') &&
            local('remote.txt').existsSync(),
      );
      expect(lastState(run.events)!['paused'], isFalse);
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
      final store = Manifest(profile);
      expect(store.setting('paused'), '0');
      store.close();
    });

    test('a pause during a pass ends it at the next path boundary', () async {
      final cloud = CountingCloud();
      for (var i = 0; i < 400; i++) {
        local('f$i.txt').writeAsStringSync('file $i');
      }
      final run = startLoop(cloud);
      await eventually(() => cloud.uploads > 0);
      run.input.add({'action': 'pause'});
      await eventually(() => lastState(run.events)?['paused'] == true);
      final uploads = cloud.uploads;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(cloud.uploads, lessThanOrEqualTo(uploads + 1));
      expect(cloud.uploads, lessThan(400));
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
    });
  });

  group('remote cadence (real worker, short intervals)', () {
    test('idle listing follows the schedule; local edits and the window '
        'list early', () async {
      final cloud = CountingCloud();
      final run = startLoop(
        cloud,
        schedule: RemoteSchedule(
          idle: const Duration(milliseconds: 600),
          fast: const Duration(milliseconds: 600),
        ),
      );
      await eventually(() => cloud.snapshots >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // ~40 ms local passes, but the cloud is listed only every ~600 ms.
      expect(cloud.snapshots, inInclusiveRange(2, 4));
      final before = cloud.snapshots;
      local('new.txt').writeAsStringSync('local edit');
      await eventually(() => cloud.files.containsKey('new.txt'));
      expect(cloud.snapshots, before + 1, reason: 'local work lists at once');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final shown = cloud.snapshots;
      final at = DateTime.now();
      run.input.add({'action': 'visible'});
      await eventually(() => cloud.snapshots > shown);
      expect(
        cloud.snapshotTimes.last.difference(at).inMilliseconds,
        lessThan(300),
      );
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
    });

    test('offline: backoff grows, local edits do not force listings, '
        'status is Offline', () async {
      final cloud = CountingCloud()..online = false;
      final run = startLoop(
        cloud,
        interval: const Duration(milliseconds: 20),
        schedule: RemoteSchedule(
          backoffBase: const Duration(milliseconds: 200),
          random: Random(1),
        ),
      );
      await eventually(
        () => cloud.snapshots >= 4,
        timeout: const Duration(seconds: 6),
      );
      local('offline.txt').writeAsStringSync('edited offline');
      final times = cloud.snapshotTimes;
      final gaps = [
        for (var i = 1; i < 4; i++)
          times[i].difference(times[i - 1]).inMilliseconds,
      ];
      expect(gaps[1], greaterThan(gaps[0]));
      expect(gaps[2], greaterThan(gaps[1]));
      expect(lastState(run.events)!['status'], 'offline');
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
    });
  });

  group('clean quit', () {
    test('quit during a transfer abandons it at the bound; WAL checkpointed; '
        'intent durable; restart converges', () async {
      final cloud = BlockingCloud();
      local('big.bin').writeAsStringSync('payload' * 1000);
      final run = startLoop(
        cloud,
        abortGrace: const Duration(milliseconds: 300),
      );
      await cloud.started.future.timeout(const Duration(seconds: 10));
      final watch = Stopwatch()..start();
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(cloud.closed, isTrue);
      expect(run.events.last, {'event': 'stopped', 'abandoned': true});
      expect(wal().existsSync(), isFalse);
      expect(File('${profile.path}/manifest.sqlite-shm').existsSync(), isFalse);
      final store = Manifest(profile);
      final intents = store.operations.values.where(
        (o) => o.kind == 'upload' && o.path == 'big.bin',
      );
      expect(intents, hasLength(1), reason: 'the intent stays durable');
      expect(intents.single.data['dispatchState'], 'started');
      store.close();

      final healthy = CountingCloud();
      final restart = startLoop(healthy);
      await eventually(() => healthy.files.containsKey('big.bin'));
      await eventually(() {
        final state = lastState(restart.events);
        final entries = (state?['entries'] as List?) ?? const [];
        return entries.any(
          (e) => e['path'] == 'big.bin' && e['status'] == 'current local',
        );
      });
      restart.input.add({'action': 'stop'});
      await restart.done.timeout(const Duration(seconds: 10));
      final after = Manifest(profile);
      expect(after.operations.values.where((o) => o.kind == 'upload'), isEmpty);
      expect(after.entries['big.bin']!.conflict, isNull);
      after.close();
    });

    test('quit during a large pass stops at a path boundary', () async {
      final cloud = CountingCloud();
      for (var i = 0; i < 1500; i++) {
        local('p$i.txt').writeAsStringSync('content $i');
      }
      final run = startLoop(cloud);
      await eventually(() => cloud.uploads > 5);
      final watch = Stopwatch()..start();
      run.input.add({'action': 'stop'});
      await run.done.timeout(const Duration(seconds: 10));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(cloud.uploads, lessThan(1500));
      expect(run.events.last['event'], 'stopped');
      expect(run.events.last['abandoned'], isFalse);
      expect(wal().existsSync(), isFalse);
    });

    test(
      'a Pause chosen while the worker starts is kept and persisted',
      () async {
        final controllerProfile = Directory('${fixture.path}/starting');
        final files = Directory('${fixture.path}/starting-files')..createSync();
        final first = ClientController(
          controllerProfile,
          secrets: MemorySecrets(),
          nativeLibrary: testNativeLibrary,
        );
        await first.initialize();
        await first.configureRoot(files.path);
        expect(await first.stop(), isTrue);

        final controller = ClientController(
          controllerProfile,
          secrets: MemorySecrets(),
          nativeLibrary: testNativeLibrary,
        );
        final initializing = controller.initialize();
        // The worker is spawning: no input port yet.
        controller.setPaused(true);
        await initializing;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(controller.paused, isTrue, reason: 'not reverted by state');
        expect(controller.status, SyncStatus.paused);
        expect(await controller.stop(), isTrue);
        final store = Manifest(controllerProfile);
        expect(store.setting('paused'), '1');
        store.close();
      },
    );

    test('controller stop closes the worker manifest (no -wal left)', () async {
      final controllerProfile = Directory('${fixture.path}/controller');
      final controller = ClientController(
        controllerProfile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      await controller.initialize();
      final files = Directory('${fixture.path}/controller-files')..createSync();
      await controller.configureRoot(files.path);
      File('${controller.root}/hello.txt').writeAsStringSync('hello');
      await eventually(
        () => controller.entries.any((e) => e['path'] == 'hello.txt'),
      );
      expect(
        File('${controllerProfile.path}/manifest.sqlite-wal').existsSync(),
        isTrue,
        reason: 'the running worker holds the WAL open',
      );
      expect(await controller.stop(), isTrue);
      expect(
        File('${controllerProfile.path}/manifest.sqlite-wal').existsSync(),
        isFalse,
      );
      controller.setPaused(true);
      final store = Manifest(controllerProfile);
      expect(store.setting('paused'), '1');
      store.close();
    });
  });
}
