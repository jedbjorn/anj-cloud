import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/upload_backoff.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Jitter fixed at one point of its range.
class _Jitter implements Random {
  _Jitter(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

/// Fails uploads of chosen paths only; every other path behaves normally.
class _PathFailCloud extends FakeCloud {
  final Map<String, Object> errors = {};
  final Map<String, int> attemptsBy = {};

  /// An upload of a path listed here waits until its completer completes.
  final Map<String, Completer<void>> gates = {};
  final Map<String, Completer<void>> started = {};
  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    attemptsBy[path] = (attemptsBy[path] ?? 0) + 1;
    started[path]?.complete();
    await gates[path]?.future;
    final error = errors[path];
    if (error != null) {
      uploadAttempts++;
      throw error;
    }
    return super.upload(path, source, etag: etag);
  }
}

const _brokenPipe = TransferInterrupted(
  'SocketException: Broken pipe (OS Error: Broken pipe, errno = 32)',
  TransferFailure.write,
);

void main() {
  // Deletions under Documents here are not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _PathFailCloud cloud;
  late SyncEngine engine;
  late Duration now;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-upload-limit-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'limit', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _PathFailCloud();
    engine = SyncEngine(store, tree, cloud);
    now = Duration.zero;
    engine.uploads = UploadBackoff(clock: () => now, random: _Jitter(0));
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  void write(String path, int size) =>
      local(path).writeAsBytesSync(List.filled(size, 65), flush: true);
  Entry entry(String path) => store.entries[path]!;
  Future<Map<String, dynamic>> projected(String path) async =>
      Map<String, dynamic>.from(await projectEntry(engine, entry(path)));
  SyncStatus overall() => deriveStatus(
    paused: false,
    offline: false,
    unpaired: false,
    message: engine.message,
    entries: store.entries.values,
    operations: store.operations.values,
  );

  /// Paths shown as syncing at any moment of the next pass.
  Future<Set<String>> tickWatchingActivity() async {
    final seen = <String>{};
    engine.activity.onChanged = () => seen.addAll(engine.activity.paths);
    await engine.tick();
    engine.activity.onChanged = null;
    return seen;
  }

  const big = 'Documents/big.bin';
  const tooLarge =
      'Too large for the server (limit 64 MB). It stays on this device.';

  test('a 413 needs attention, stays amber, and is never retried', () async {
    write(big, 4096);
    cloud.errors[big] = const UploadTooLarge(limit: 64 * 1024 * 1024);
    await engine.tick();
    expect(cloud.attemptsBy[big], 1);
    expect(entry(big).status, tooLarge);
    final row = await projected(big);
    expect(needsAttention(row), isTrue);
    // SC-033: the badge agrees with the amber bar; nothing is queued.
    expect(fileBadge(row), 'Needs attention');
    expect(libraryStatus(row), tooLarge);
    expect(overall(), SyncStatus.attention);
    // Neither time nor further passes bring it back, and it never shows as
    // syncing (no blue flash, #27).
    for (final step in [1, 60, 3600, 86400]) {
      now += Duration(seconds: step);
      final seen = await tickWatchingActivity();
      expect(seen, isNot(contains(big)));
      expect(entry(big).status, tooLarge);
    }
    expect(cloud.attemptsBy[big], 1);
    expect(activeSyncing([row], {big}), isEmpty);
    expect(local(big).lengthSync(), 4096, reason: 'it stays on this device');
  });

  test('over the reported limit: never staged, never sent', () async {
    cloud.uploadLimit = 1024;
    write(big, 2048);
    final seen = await tickWatchingActivity();
    expect(cloud.attemptsBy[big], isNull);
    expect(seen, isNot(contains(big)));
    expect(
      entry(big).status,
      'Too large for the server (limit 1 KB). It stays on this device.',
    );
    expect(store.operations.values.where((o) => o.kind == 'upload'), isEmpty);
    expect(needsAttention(await projected(big)), isTrue);
    expect(fileBadge(await projected(big)), 'Needs attention');
    expect(overall(), SyncStatus.attention);
  });

  test('a file that shrinks under the limit syncs again', () async {
    cloud.uploadLimit = 1024;
    write(big, 2048);
    await engine.tick();
    expect(cloud.attemptsBy[big], isNull);
    write(big, 1000);
    await engine.tick();
    expect(cloud.files[big]!.length, 1000);
    expect(entry(big).status, 'current local');
    expect(needsAttention(await projected(big)), isFalse);
    expect(overall(), SyncStatus.upToDate);

    // The same for a refusal the server made with a 413.
    write(big, 4096);
    cloud.errors[big] = const UploadTooLarge(limit: 3000);
    await engine.tick();
    expect(cloud.attemptsBy[big], 1);
    cloud.errors.remove(big);
    cloud.uploadLimit = 3000;
    await engine.tick();
    expect(cloud.attemptsBy[big], 1, reason: 'unchanged: still held');
    write(big, 2999);
    await engine.tick();
    expect(cloud.attemptsBy[big], 2);
    expect(cloud.files[big]!.length, 2999);
  });

  test('a raised server limit or a user retry releases a refusal', () async {
    cloud.uploadLimit = 1024;
    write(big, 2048);
    await engine.tick();
    expect(entry(big).status, startsWith('Too large'));
    cloud.uploadLimit = 4096;
    await engine.tick();
    expect(cloud.files[big]!.length, 2048);

    write(big, 8192);
    await engine.tick();
    expect(entry(big).status, startsWith('Too large'));
    engine.uploads.retryAll(); // Pause then Resume, or an explicit refresh.
    await engine.tick();
    expect(
      entry(big).status,
      startsWith('Too large'),
      reason: 'retried locally against the same limit: still nothing sent',
    );
    expect(cloud.attemptsBy[big], 1);
  });

  test('interrupted transfers back off exponentially (fake clock)', () async {
    write(big, 4096);
    cloud.errors[big] = _brokenPipe;
    await engine.tick();
    expect(cloud.attemptsBy[big], 1);
    expect(entry(big).status, startsWith('pending: SocketException'));
    expect(needsAttention(await projected(big)), isTrue, reason: 'amber');
    var attempts = 1;
    // 15 s doubling, capped at 15 min (no jitter here).
    for (final seconds in [15, 30, 60, 120, 240, 480, 900, 900, 900]) {
      now += Duration(seconds: seconds) - const Duration(milliseconds: 1);
      final seen = await tickWatchingActivity();
      expect(cloud.attemptsBy[big], attempts, reason: 'not before $seconds s');
      expect(seen, isNot(contains(big)));
      expect(entry(big).status, startsWith('pending: SocketException'));
      now += const Duration(milliseconds: 1);
      await engine.tick();
      expect(cloud.attemptsBy[big], ++attempts, reason: 'due at $seconds s');
    }
    // Success clears the backoff for good.
    cloud.errors.remove(big);
    now += const Duration(minutes: 15);
    await engine.tick();
    expect(cloud.files[big]!.length, 4096);
    expect(engine.uploads.length, 0);
    expect(entry(big).status, 'current local');
  });

  test('jitter only ever delays, by at most a quarter', () {
    for (final value in [0.0, 0.5, 0.999]) {
      var at = Duration.zero;
      final backoff = UploadBackoff(clock: () => at, random: _Jitter(value));
      for (var i = 0; i < 8; i++) {
        backoff.failed('a', 's', _brokenPipe, size: 1);
        final hold = backoff.hold('a', 's')!;
        final nominal = Duration(seconds: min(15 * (1 << i), 900));
        final delay = hold.notBefore - at;
        expect(delay, greaterThanOrEqualTo(nominal));
        expect(
          delay,
          lessThanOrEqualTo(
            Duration(seconds: min((15 * (1 << i) * 1.25).ceil(), 900)),
          ),
        );
        at = hold.notBefore;
      }
    }
  });

  test('editing the file resets its backoff at once', () async {
    write(big, 4096);
    cloud.errors[big] = _brokenPipe;
    await engine.tick();
    now += const Duration(seconds: 15);
    await engine.tick();
    expect(cloud.attemptsBy[big], 2, reason: 'next wait is 30 s');
    write(big, 4000);
    cloud.errors.remove(big);
    now += const Duration(seconds: 1);
    await engine.tick();
    expect(cloud.files[big]!.length, 4000);
  });

  test('one failing file does not hold up the others', () async {
    write(big, 4096);
    write('Documents/a.txt', 10);
    write('Documents/b.txt', 20);
    cloud.errors[big] = _brokenPipe;
    await engine.tick();
    expect(cloud.files['Documents/a.txt']!.length, 10);
    expect(cloud.files['Documents/b.txt']!.length, 20);
    // While big backs off, new edits elsewhere sync on every pass.
    for (var i = 1; i <= 3; i++) {
      write('Documents/a.txt', 10 + i);
      now += const Duration(seconds: 2);
      await engine.tick();
      expect(cloud.files['Documents/a.txt']!.length, 10 + i);
    }
    expect(cloud.attemptsBy[big], 1);
    expect(overall(), SyncStatus.syncing, reason: 'big is still pending');
  });

  test('a failure while the root is unavailable is not a transfer failure', () {
    final backoff = UploadBackoff(clock: () => now);
    expect(
      backoff.failed(
        'a',
        's',
        const CloudFailure('changed', status: 412),
        size: 1,
      ),
      isNull,
    );
    expect(
      backoff.failed('a', 's', const FileSystemException('root gone'), size: 1),
      isNull,
    );
    expect(
      backoff.failed('a', 's', const CloudFailure('Sync is paused.'), size: 1),
      isNull,
    );
    expect(backoff.length, 0);
  });

  group('older gateway (mid-body abort, no 413, no reported limit)', () {
    test(
      'three broken connections of a file over 64 MB: "may be too large"',
      () {
        final backoff = UploadBackoff(clock: () => now, random: _Jitter(0));
        const size = 300 * 1024 * 1024;
        String? status;
        for (var i = 0; i < 3; i++) {
          expect(backoff.waiting('p', 's'), isFalse);
          status = backoff.failed('p', 's', _brokenPipe, size: size);
          now = backoff.hold('p', 's')!.notBefore;
        }
        expect(
          status,
          'May be too large for the server (limit 64 MB). It stays on this device.',
        );
        now += const Duration(days: 1);
        expect(backoff.waiting('p', 's'), isTrue, reason: 'no automatic retry');
        expect(backoff.waiting('p', 'edited'), isFalse);
      },
    );

    test(
      'engine: bounded attempts, then attention; small files keep trying',
      () async {
        engine.uploads = UploadBackoff(
          clock: () => now,
          random: _Jitter(0),
          assumedLimit: 1024,
        );
        const small = 'Documents/small.bin';
        write(big, 2048);
        write(small, 512);
        cloud.errors[big] = _brokenPipe;
        cloud.errors[small] = _brokenPipe;
        // Passes every 2 s for 2 minutes, as the worker would at most.
        for (var t = 0; t <= 120; t += 2) {
          now = Duration(seconds: t);
          await engine.tick();
        }
        expect(
          cloud.attemptsBy[big],
          3,
          reason: 'at 0, 15 and 45 s; then stop',
        );
        expect(
          entry(big).status,
          'May be too large for the server (limit 1 KB). It stays on this device.',
        );
        expect(needsAttention(await projected(big)), isTrue);
        expect(cloud.attemptsBy[small], 4, reason: '0, 15, 45, 105 s');
        expect(entry(small).status, startsWith('pending: '));
        now += const Duration(hours: 1);
        await engine.tick();
        expect(cloud.attemptsBy[big], 3);
      },
    );

    test('alternating failure kinds are not identical: no guess', () {
      final backoff = UploadBackoff(clock: () => now, random: _Jitter(0));
      const timeout = TransferInterrupted(
        'Server did not respond.',
        TransferFailure.timeout,
      );
      for (final error in [_brokenPipe, _brokenPipe, timeout, _brokenPipe]) {
        final status = backoff.failed('p', 's', error, size: 1 << 30);
        expect(status, startsWith('pending: '));
      }
    });
  });

  group('a file removed before it ever synchronized', () {
    Future<void> expectInDeviceTrash(String bytes) async {
      expect(entry(big).status, 'removed locally');
      expect(store.operations.values.where((o) => o.kind == 'upload'), isEmpty);
      // Spec #44: the only copy of these bytes is in the device trash, not
      // a Recovery row.
      expect(
        store.operations.values.where(
          (o) => o.kind == 'retained' && o.path == big,
        ),
        isEmpty,
      );
      final kept = store.operations.values
          .where((o) => o.kind == 'trash' && o.path == big)
          .toList();
      expect(kept, hasLength(1));
      expect(File(kept.single.staged!).readAsStringSync(), bytes);
      final row = await projected(big);
      expect(isTerminalDeletion(row), isTrue);
      expect(hasQueuedWork(row), isFalse);
      expect(visibleInLibrary(row), isFalse);
      expect(overall(), SyncStatus.upToDate, reason: 'not Syncing');
      expect(engine.uploads.length, 0);
      // Settled: no retries, nothing shown as syncing, no re-read of the copy.
      final attempts = cloud.attemptsBy[big];
      final checks = tree.native.meter.filesBy['retained-check'] ?? 0;
      for (var i = 0; i < 3; i++) {
        now += const Duration(hours: 1);
        expect(await tickWatchingActivity(), isEmpty);
      }
      expect(cloud.attemptsBy[big], attempts);
      expect(entry(big).status, 'removed locally');
      expect(tree.native.meter.filesBy['retained-check'] ?? 0, checks);
      expect(cloud.files.containsKey(big), isFalse);
    }

    test('deleted while queued after a failed upload', () async {
      local(big).writeAsStringSync('local only bytes');
      cloud.errors[big] = _brokenPipe;
      await engine.tick();
      expect(entry(big).status, startsWith('pending: '));
      local(big).deleteSync();
      await engine.tick();
      await expectInDeviceTrash('local only bytes');
    });

    test('deleted after a 413 needs-attention state', () async {
      local(big).writeAsStringSync('refused bytes');
      cloud.errors[big] = const UploadTooLarge(limit: 4);
      await engine.tick();
      expect(entry(big).status, startsWith('Too large'));
      local(big).deleteSync();
      await engine.tick();
      await expectInDeviceTrash('refused bytes');
    });

    test('deleted while its upload is in flight, which then fails', () async {
      local(big).writeAsStringSync('in flight');
      cloud.errors[big] = _brokenPipe;
      cloud.gates[big] = Completer<void>();
      cloud.started[big] = Completer<void>();
      final pass = engine.tick();
      await cloud.started[big]!.future;
      local(big).deleteSync();
      cloud.gates[big]!.complete();
      await pass;
      await engine.tick();
      await expectInDeviceTrash('in flight');
    });

    test(
      'deleted while in flight, upload succeeds: the delete propagates',
      () async {
        local(big).writeAsStringSync('landed');
        cloud.gates[big] = Completer<void>();
        cloud.started[big] = Completer<void>();
        final pass = engine.tick();
        await cloud.started[big]!.future;
        local(big).deleteSync();
        cloud.gates[big]!.complete();
        await pass;
        await engine.tick();
        expect(cloud.files.containsKey(big), isFalse);
        expect(cloud.deletes, 1);
        expect(overall(), SyncStatus.upToDate);
      },
    );

    test('never staged (over the reported limit): the row just ends', () async {
      cloud.uploadLimit = 4;
      local(big).writeAsStringSync('too big');
      await engine.tick();
      local(big).deleteSync();
      await engine.tick();
      expect(entry(big).status, 'removed locally');
      expect(
        store.operations.values.where(
          (o) => o.path == big && o.kind != 'artifact',
        ),
        isEmpty,
      );
      expect(visibleInLibrary(await projected(big)), isFalse);
      expect(overall(), SyncStatus.upToDate);
    });

    test(
      'a stuck entry persisted by an earlier release clears on upgrade',
      () async {
        // The state Laptop holds: a failed upload's intent and complete
        // snapshot, the source rm'd, the row stuck at "pending: …".
        local(big).writeAsStringSync('probe bytes');
        cloud.errors[big] = const CloudFailure('Write failed');
        await engine.tick();
        engine.close();
        local(big).deleteSync();
        final profile = Directory('${fixture.path}/profile');
        final earlier = Manifest(profile);
        earlier.entries[big]!.status =
            'pending: SocketException: Broken pipe (OS Error: Broken pipe, '
            'errno = 32), address = 127.0.0.1, port = 47172';
        earlier.save();
        expect(
          earlier.operations.values
              .where((o) => o.kind == 'upload')
              .single
              .data['dispatchState'],
          'started',
        );
        earlier.close();
        store = Manifest(profile);
        tree = RootTree(tree.root, tree.staging, NativeRootFs());
        engine = SyncEngine(store, tree, cloud);
        engine.uploads = UploadBackoff(clock: () => now, random: _Jitter(0));
        await engine.tick();
        await expectInDeviceTrash('probe bytes');
      },
    );
  });

  test('retries reuse the staged snapshot until the file changes', () async {
    write(big, 100000);
    cloud.errors[big] = _brokenPipe;
    final meter = tree.native.meter;
    int staged() => meter.bytesBy['upload-snapshot'] ?? 0;
    await engine.tick();
    expect(staged(), 100000);
    for (final seconds in [15, 30, 60]) {
      now += Duration(seconds: seconds);
      await engine.tick();
    }
    expect(cloud.attemptsBy[big], 4);
    expect(staged(), 100000, reason: 'one snapshot for four attempts');
    write(big, 90000);
    await engine.tick();
    expect(cloud.attemptsBy[big], 5);
    expect(staged(), 190000, reason: 'changed bytes are staged again');
    cloud.errors.remove(big);
    now += const Duration(seconds: 15);
    await engine.tick();
    expect(cloud.files[big]!.length, 90000);
    expect(staged(), 190000);
  });

  test('worker: Resume and an explicit refresh retry held uploads', () async {
    final events = <Object?>[];
    final input = StreamController<Object?>();
    write(big, 4096);
    cloud.errors[big] = const UploadTooLarge(limit: 1000);
    final loop = WorkerLoop(
      engine,
      events.add,
      interval: const Duration(milliseconds: 20),
    );
    final done = loop.run(input.stream);
    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 500 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    await until(() => cloud.attemptsBy[big] == 1);
    cloud.errors.remove(big);
    input.add({'action': 'pause'});
    input.add({'action': 'resume'});
    await until(() => cloud.files[big]?.length == 4096);
    write(big, 5000);
    cloud.errors[big] = _brokenPipe;
    await until(() => cloud.attemptsBy[big] == 3);
    cloud.errors.remove(big);
    input.add({'action': 'tick'});
    await until(() => cloud.files[big]?.length == 5000);
    input.add({'action': 'stop'});
    await done;
    await input.close();
    // The loop closed the engine; tearDown closes it again harmlessly.
    engine = SyncEngine(
      Manifest(Directory('${fixture.path}/profile')),
      RootTree(tree.root, tree.staging, NativeRootFs()),
      cloud,
    );
  });
}
