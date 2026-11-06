// Spec #28 A4: background runs, the network setting ("Wi-Fi only", decision
// #108 Q4, R3) and the notification glue. Runs on Linux with the Android
// adapters over the Linux build of the same anj_* ABI; the runner side
// (WorkManager, the dataSync service, connectivity) is proven on the
// emulator (tool/android/emu_background.sh).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/android/background.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _CountingCloud extends FakeCloud {
  int listings = 0;
  int downloads = 0;

  /// Called after each listing (test hook).
  void Function()? onListed;
  @override
  Future<List<RemoteItem>> snapshot() async {
    listings++;
    final items = await super.snapshot();
    onListed?.call();
    return items;
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    downloads++;
    return super.download(path, target, etag: etag);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _CountingCloud cloud;
  late PausableCloud gate;
  late SyncEngine engine;
  var closed = false;

  File local(String path) => File('${tree.root.path}/$path');
  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  Future<void> until(bool Function() done, {int seconds = 20}) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    closed = false;
    fixture = Directory.systemTemp.createTempSync('anj-background-');
    tree = RootTree.setup(
      fixture.path,
      'background',
      AndroidRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']),
    );
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _CountingCloud();
    gate = PausableCloud(cloud);
    for (var i = 0; i < 5; i++) {
      local('Documents/f$i.txt').writeAsStringSync('file $i');
    }
    engine = SyncEngine(
      store,
      tree,
      gate,
      watchers: const AndroidChangeWatchers(),
    );
    await engine.startWatching();
    (engine.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
  });

  tearDown(() {
    // Tests that ran a worker loop closed the engine when it stopped.
    if (!closed) engine.close();
    fixture.deleteSync(recursive: true);
  });

  /// A running worker loop with the Android settings; [events] collects
  /// everything it sends. Stop with [stop].
  Future<
    ({
      List<Map> events,
      StreamController<Object?> input,
      WorkerLoop loop,
      Future<void> Function() stop,
    })
  >
  start({
    String? policy = 'wifi',
    Future<void> Function()? pickup,
    Duration joinedListingAge = const Duration(seconds: 60),
    void Function(StreamController<Object?> input)? beforeRun,
  }) async {
    final events = <Map>[];
    final input = StreamController<Object?>();
    beforeRun?.call(input);
    final loop = WorkerLoop(
      engine,
      (event) => events.add(event as Map),
      gate: gate,
      // The idle listing is far off: anything sooner is event-driven.
      schedule: RemoteSchedule(idle: const Duration(seconds: 60)),
      defaultNetworkPolicy: policy,
      pickupIfDue: pickup,
      joinedListingAge: joinedListingAge,
    );
    final done = loop.run(input.stream);
    Future<void> stop() async {
      input.add({'action': 'stop'});
      await done;
      closed = true;
      await input.close();
    }

    return (events: events, input: input, loop: loop, stop: stop);
  }

  Map? reply(List<Map> events, String request) {
    for (final event in events) {
      if (event['event'] == 'backgroundDone' && event['request'] == request) {
        return event;
      }
    }
    return null;
  }

  group('background runs (WorkManager)', () {
    test('a background run triggers one full verification pass', () async {
      final run = await start(policy: null);
      try {
        await until(() => remote('Documents/f4.txt') == 'file 4');
        // Let the start-up passes settle into the event-driven idle.
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(engine.eventDriven, isTrue);
        final verifications = engine.fullVerifications;
        final listings = cloud.listings;
        run.input.add({'action': 'background', 'request': 'r1'});
        await until(() => reply(run.events, 'r1') != null);
        final done = reply(run.events, 'r1')!;
        expect(engine.fullVerifications, verifications + 1);
        expect(engine.lastPass!.filesHashedBy['scan'], greaterThanOrEqualTo(5));
        expect(cloud.listings, greaterThan(listings));
        expect(done['listed'], isTrue);
        expect(done['paused'], isFalse);
        expect(done['fullVerifications'], verifications + 1);
      } finally {
        await run.stop();
      }
    });

    test('while paused: answered at once after an overdue pickup, '
        'and nothing else reaches the network', () async {
      store.setSetting('paused', '1');
      var pickups = 0;
      final run = await start(policy: null, pickup: () async => pickups++);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final listings = cloud.listings;
        final hashed = tree.native.meter.files;
        final verifications = engine.fullVerifications;
        run.input.add({'action': 'background', 'request': 'p1'});
        await until(() => reply(run.events, 'p1') != null);
        expect(
          tree.native.meter.files,
          hashed,
          reason: 'a paused background run hashes nothing',
        );
        expect(engine.fullVerifications, verifications);
        expect(reply(run.events, 'p1')!['paused'], isTrue);
        expect(pickups, 1, reason: 'certificate pickup runs while paused');
        expect(cloud.listings, listings);
        expect(cloud.uploads, 0);
      } finally {
        await run.stop();
      }
    });

    test('a cold-start background run does exactly one full verification '
        '(#130 (3)): it joins the start-up pass', () async {
      final run = await start(policy: null);
      try {
        // Arrives while the start-up pass, itself a full verification, runs.
        run.input.add({'action': 'background', 'request': 'cold'});
        await until(() => reply(run.events, 'cold') != null);
        final done = reply(run.events, 'cold')!;
        expect(done['listed'], isTrue);
        expect(done['fullVerifications'], 1);
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(engine.fullVerifications, 1, reason: 'no second verification');
      } finally {
        await run.stop();
      }
    });

    /// A run that arrives just after the start-up pass listed: it joins
    /// that full verification, and its listing is judged by age.
    Future<({Map done, int listingsAtReply})> joinAfterListing(
      Duration joinedListingAge,
    ) async {
      var sent = false;
      final run = await start(
        policy: null,
        joinedListingAge: joinedListingAge,
        beforeRun: (input) => cloud.onListed = () {
          if (sent) return;
          sent = true;
          input.add({'action': 'background', 'request': 'late'});
        },
      );
      try {
        await until(() => reply(run.events, 'late') != null);
        return (
          done: reply(run.events, 'late')!,
          listingsAtReply: cloud.listings,
        );
      } finally {
        await run.stop();
      }
    }

    test(
      'a joined run uses a listing made at most 60 s before it asked',
      () async {
        final result = await joinAfterListing(const Duration(seconds: 60));
        expect(result.done['fullVerifications'], 1);
        expect(result.done['listed'], isTrue);
        expect(result.listingsAtReply, 1, reason: 'the joined pass listed');
      },
    );

    test('a joined run whose listing is too old gets one follow-up listing, '
        'not a second verification', () async {
      // An age of zero: the start-up listing came before the request.
      final result = await joinAfterListing(Duration.zero);
      expect(result.done['fullVerifications'], 1);
      expect(result.done['listed'], isTrue);
      expect(result.listingsAtReply, 2);
      expect(engine.fullVerifications, 1);
    });

    test('F3: a pickup already under way is awaited, not skipped', () async {
      final release = Completer<void>();
      var attempts = 0;
      final renewal = CertificateRenewal(
        (_) async {
          attempts++;
          await release.future;
          return PickupResult(
            PickupOutcome.values.first,
            'pem',
            DateTime.now().add(const Duration(days: 300)),
          );
        },
        expires: DateTime.now().add(const Duration(days: 300)),
        onRenewed: (_) {},
        onStatus: (_, _) {},
      );
      renewal.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 1, reason: 'the start-up pickup is in flight');
      var waited = false;
      final pending = renewal.runIfDue().then((_) => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(waited, isFalse, reason: 'runIfDue waits for the pickup');
      release.complete();
      await pending;
      expect(waited, isTrue);
      expect(attempts, 1, reason: 'joined, not repeated');
      renewal.stop();
    });
  });

  test('foreground: a reported local change uploads promptly while the '
      'next listing is a minute away', () async {
    final run = await start(policy: null);
    try {
      await until(() => remote('Documents/f4.txt') == 'file 4');
      await Future<void>.delayed(const Duration(seconds: 2));
      final watch = Stopwatch()..start();
      local('Documents/new.txt').writeAsStringSync('prompt');
      await until(() => remote('Documents/new.txt') == 'prompt', seconds: 10);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    } finally {
      await run.stop();
    }
  });

  group('Wi-Fi only (decision #108 Q4, R3: only bytes wait)', () {
    test(
      'the default holds bytes until Wi-Fi is reported; listings run',
      () async {
        cloud.put('Music/song.txt', 'remote bytes');
        final run = await start();
        try {
          // No network report yet: unknown counts as not Wi-Fi.
          await until(() => cloud.listings >= 1);
          await until(
            () =>
                store.entries['Music/song.txt']?.status == waitingForWifiStatus,
          );
          expect(
            store.entries['Documents/f0.txt']!.status,
            waitingForWifiStatus,
          );
          expect(cloud.uploadAttempts, 0);
          expect(cloud.downloads, 0);
          expect(local('Music/song.txt').existsSync(), isFalse);
          expect(engine.transfersHeld, isTrue);
          final state = run.events.lastWhere((e) => e['event'] == 'state');
          expect(state['status'], SyncStatus.waiting.name);
          expect(state['networkPolicy'], 'wifi');
          expect(state['transfersHeld'], isTrue);

          // On mobile data the hold stays.
          run.input.add({'action': 'network', 'wifi': false});
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(cloud.uploadAttempts, 0);

          // Wi-Fi returns: everything waiting moves, without a new edit.
          run.input.add({'action': 'network', 'wifi': true});
          await until(() => remote('Documents/f0.txt') == 'file 0');
          await until(() => local('Music/song.txt').existsSync());
          expect(local('Music/song.txt').readAsStringSync(), 'remote bytes');
          expect(engine.waitingForNetwork, isEmpty);
        } finally {
          await run.stop();
        }
      },
    );

    test(
      '"Wi-Fi or mobile data" transfers on mobile data and persists',
      () async {
        final run = await start();
        try {
          run.input.add({'action': 'network', 'wifi': false});
          await until(
            () =>
                store.entries['Documents/f0.txt']?.status ==
                waitingForWifiStatus,
          );
          run.input.add({'action': 'networkPolicy', 'value': 'any'});
          await until(() => remote('Documents/f4.txt') == 'file 4');
          expect(store.setting('network'), 'any');
          expect(run.loop.networkPolicy, 'any');
        } finally {
          await run.stop();
        }
      },
    );

    test('a background run on mobile data reports what waits', () async {
      final run = await start();
      try {
        run.input.add({'action': 'network', 'wifi': false});
        run.input.add({'action': 'background', 'request': 'cell'});
        await until(() => reply(run.events, 'cell') != null);
        final done = reply(run.events, 'cell')!;
        expect(done['listed'], isTrue, reason: 'listings run on any network');
        expect(done['waiting'], 5);
        expect(cloud.uploadAttempts, 0);
      } finally {
        await run.stop();
      }
    });

    test(
      'an open of a Cloud-only file waits for Wi-Fi and downloads nothing',
      () async {
        cloud.put('Videos/clip.txt', 'clip');
        engine.transfersHeld = true;
        gate.bytesHeld = true;
        await engine.tick();
        final entry = store.entries['Videos/clip.txt']!;
        expect(entry.status, waitingForWifiStatus);
        expect(entry.expectedPresent, isFalse);
        await expectLater(
          engine.openFile('Videos/clip.txt'),
          throwsA(
            isA<TransfersHeld>().having(
              (e) => e.message,
              'message',
              startsWith('Waiting for Wi-Fi'),
            ),
          ),
        );
        expect(cloud.downloads, 0);
        expect(local('Videos/clip.txt').existsSync(), isFalse);
      },
    );

    test(
      'F5: a held upload-acknowledgement recovery waits for Wi-Fi',
      () async {
        await engine.tick();
        local('Documents/lost.txt').writeAsStringSync('lost ack');
        cloud.loseNextUploadAcknowledgement = true;
        bool pending() => store.operations.values.any(
          (o) => o.kind == 'upload' && o.path == 'Documents/lost.txt',
        );
        // The watcher reports the new file after its quiet period.
        for (var i = 0; i < 50 && !pending(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
        }
        expect(
          pending(),
          isTrue,
          reason: 'the acknowledgement was lost: recovery is pending',
        );
        engine.transfersHeld = true;
        gate.bytesHeld = true;
        final refused = gate.heldTransfers;
        cloud.loseNextUploadAcknowledgement = false;
        await engine.tick();
        final entry = store.entries['Documents/lost.txt']!;
        expect(entry.status, waitingForWifiStatus);
        expect(entry.status, isNot(contains('recovery pending')));
        expect(engine.waitingForNetwork, contains('Documents/lost.txt'));
        expect(gate.heldTransfers, greaterThanOrEqualTo(refused));
      },
    );

    test('F5: a held working-edit upload waits for Wi-Fi', () async {
      await engine.tick();
      await engine.tick();
      final copy = await engine.openFile('Documents/f0.txt');
      File(copy).writeAsStringSync('edited in another app');
      engine.transfersHeld = true;
      gate.bytesHeld = true;
      final attempts = cloud.uploadAttempts;
      await engine.tick();
      expect(engine.waitingForNetwork, contains('Documents/f0.txt'));
      final work = store.operations.values.singleWhere(
        (o) => o.kind == 'working' && o.path == 'Documents/f0.txt',
      );
      expect(work.data['presentationError'], waitingForWifiStatus);
      expect(cloud.uploadAttempts, attempts);
      expect(remote('Documents/f0.txt'), 'file 0');
      expect(
        deriveStatus(
          paused: false,
          offline: false,
          unpaired: false,
          message: '',
          entries: store.entries.values,
          operations: store.operations.values,
        ),
        SyncStatus.waiting,
      );
    });

    test('without a platform setting (Linux) nothing is ever held', () async {
      final run = await start(policy: null);
      try {
        run.input.add({'action': 'network', 'wifi': false});
        await until(() => remote('Documents/f4.txt') == 'file 4');
        expect(engine.transfersHeld, isFalse);
        expect(run.loop.networkPolicy, isNull);
      } finally {
        await run.stop();
      }
    });
  });

  group('cloud gate', () {
    test('bytes held: upload and download refused, the rest passes', () async {
      final fake = FakeCloud()..put('a.txt', 'a');
      final held = PausableCloud(fake)..bytesHeld = true;
      final target = File('${fixture.path}/t');
      target.writeAsStringSync('b');
      expect(
        () => held.download('a.txt', target, etag: fake.versions['a.txt']!),
        throwsA(isA<TransfersHeld>()),
      );
      expect(
        () => held.upload('b.txt', target, etag: null),
        throwsA(isA<TransfersHeld>()),
      );
      expect(held.heldTransfers, 2);
      expect(fake.uploadAttempts, 0);
      expect((await held.snapshot()).map((i) => i.path), contains('a.txt'));
      await held.mkdir('Folder');
      await held.deleteFile('a.txt', etag: fake.versions['a.txt']!);
      expect(fake.files.containsKey('a.txt'), isFalse);
    });

    test('pause still wins over the network hold', () async {
      final held = PausableCloud(FakeCloud())
        ..bytesHeld = true
        ..paused = true;
      expect(
        () => held.upload('b.txt', File('${fixture.path}/t'), etag: null),
        throwsA(
          isA<CloudFailure>().having(
            (e) => e,
            'type',
            isNot(isA<TransfersHeld>()),
          ),
        ),
      );
    });
  });

  test('status: waiting for Wi-Fi ranks below attention and offline', () {
    Entry entry(String status) => Entry('a', ItemKind.file)..status = status;
    SyncStatus derive(Iterable<Entry> entries, {bool offline = false}) =>
        deriveStatus(
          paused: false,
          offline: offline,
          unpaired: false,
          message: '',
          entries: entries,
          operations: const [],
        );
    expect(derive([entry(waitingForWifiStatus)]), SyncStatus.waiting);
    expect(
      derive([entry('queued'), entry(waitingForWifiStatus)]),
      SyncStatus.waiting,
    );
    expect(
      derive([entry(waitingForWifiStatus)], offline: true),
      SyncStatus.offline,
    );
    expect(
      derive([entry(waitingForWifiStatus), entry('conflict')..conflict = 'x']),
      SyncStatus.attention,
    );
    expect(SyncStatus.waiting.label, 'Waiting for Wi-Fi');
  });

  group('attention notifications (decision #108 Q14)', () {
    test(
      'conflicts and refused uploads, each announced once across starts',
      () {
        final entries = [
          {
            'path': 'Docs/a.txt',
            'conflict': 'Both versions changed.',
            'status': 'conflict',
          },
          {
            'path': 'Video/big.mov',
            'status': 'Too large for the server (64 MB limit)',
          },
          {'path': 'Docs/ok.txt', 'status': 'current local'},
        ];
        final items = attentionItems(entries);
        expect(items.map((i) => i.title), [
          'Conflict: a.txt',
          'Upload refused: big.mov',
        ]);
        final file = File('${fixture.path}/notified.json');
        expect(AttentionTracker(file).update(items).fresh, hasLength(2));
        // A new process (background run) does not repeat them.
        final again = AttentionTracker(file).update(items);
        expect(again.fresh, isEmpty);
        expect(again.resolved, isEmpty);
        // Resolved: its notification is withdrawn (F7). Then the same
        // problem again: announced again.
        final tracker = AttentionTracker(file);
        final resolved = tracker.update(items.sublist(1));
        expect(resolved.fresh, isEmpty);
        expect(resolved.resolved, ['Docs/a.txt']);
        expect(tracker.update(items).fresh, hasLength(1));
        // A path whose problem changed is replaced, not withdrawn.
        final changed = attentionItems([
          {
            'path': 'Docs/a.txt',
            'conflict': 'Local content changed before replacement.',
            'status': 'conflict',
          },
          entries[1],
        ]);
        final replaced = tracker.update(changed);
        expect(replaced.fresh.single.path, 'Docs/a.txt');
        expect(replaced.resolved, isEmpty);
      },
    );
  });

  group('runner channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late List<MethodCall> calls;
    late ClientController controller;
    late AndroidBackground background;
    late Map<String, Object?> attachReply;

    setUp(() {
      calls = [];
      attachReply = {'notifications': true, 'wifi': false};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundChannel, (call) async {
            calls.add(call);
            if (call.method == 'attach') return attachReply;
            return null;
          });
      controller = ClientController(
        Directory('${fixture.path}/ui-profile')..createSync(),
        secrets: MemorySecrets(),
        defaultNetworkPolicy: 'wifi',
      );
      background = AndroidBackground(controller);
    });

    tearDown(() {
      background.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundChannel, null);
    });

    Future<Object?> fromRunner(String method, [Object? arguments]) async {
      final codec = const StandardMethodCodec();
      final completer = Completer<Object?>();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            backgroundChannel.name,
            codec.encodeMethodCall(MethodCall(method, arguments)),
            (data) => completer.complete(
              data == null ? null : codec.decodeEnvelope(data),
            ),
          );
      return completer.future;
    }

    test('attach, transfers and attention reach the runner', () async {
      await background.start(Future.value());
      expect(calls.first.method, 'attach');
      expect(background.notificationsAllowed, isTrue);
      controller.stateReceived = true;
      controller.entries = [
        {'path': 'a.txt', 'status': waitingForWifiStatus},
        {'path': 'b.txt', 'conflict': 'Both changed.', 'status': 'conflict'},
      ];
      controller.reportMessage('changed');
      await Future<void>.delayed(Duration.zero);
      final transfers = calls.lastWhere((c) => c.method == 'transfers');
      expect(transfers.arguments, {'count': 0, 'waiting': 1});
      final attention = calls.where((c) => c.method == 'attention').toList();
      expect(attention, hasLength(1));
      expect((attention.single.arguments as Map)['items'], hasLength(1));
      controller.reportMessage('again');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attention'), hasLength(1));
    });

    test('declined notifications: nothing posted, nothing recorded', () async {
      attachReply = {'notifications': false, 'wifi': true};
      await background.start(Future.value());
      controller.stateReceived = true;
      controller.entries = [
        {'path': 'b.txt', 'conflict': 'Both changed.', 'status': 'conflict'},
      ];
      controller.reportMessage('changed');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attention'), isEmpty);
      // Allowed later: the waiting conflict is announced then.
      await fromRunner('notifications', {'allowed': true});
      expect(background.notificationsAllowed, isTrue);
      expect(calls.where((c) => c.method == 'attention'), hasLength(1));
    });

    test('F1: a restart does not repeat an announced item', () async {
      final conflict = [
        {'path': 'b.txt', 'conflict': 'Both changed.', 'status': 'conflict'},
      ];
      final record = File(
        '${controller.profile.path}/attention-notified-v2.json',
      );
      // First process: announced once, recorded.
      await background.start(Future.value());
      controller.stateReceived = true;
      controller.entries = conflict;
      controller.reportMessage('state');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attention'), hasLength(1));
      expect(record.readAsStringSync(), contains('b.txt'));
      background.dispose();

      // Restart: a new controller (no worker state yet) and the real attach.
      calls.clear();
      controller = ClientController(
        controller.profile,
        secrets: MemorySecrets(),
        defaultNetworkPolicy: 'wifi',
      );
      background = AndroidBackground(controller);
      await background.start(Future.value());
      controller.reportMessage('starting');
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), contains('attach'));
      expect(
        record.readAsStringSync(),
        contains('b.txt'),
        reason: 'an empty library before the first state forgets nothing',
      );
      // The worker's first state still has the conflict: not posted again.
      controller.stateReceived = true;
      controller.entries = conflict;
      controller.reportMessage('state');
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'attention'), isEmpty);
    });

    test('back in the foreground, transfers are reported again', () async {
      await background.start(Future.value());
      controller.stateReceived = true;
      controller.syncing = {'a.txt', 'b.txt'};
      controller.reportMessage('state');
      await Future<void>.delayed(Duration.zero);
      int reports() => calls.where((c) => c.method == 'transfers').length;
      final before = reports();
      controller.reportMessage('same counts');
      await Future<void>.delayed(Duration.zero);
      expect(reports(), before, reason: 'unchanged counts are not repeated');
      // MainActivity.onResume cleared the service cap.
      await fromRunner('foreground');
      expect(reports(), before + 1);
      expect(calls.last.method, 'transfers');
      expect(calls.last.arguments, {'count': 2, 'waiting': 0});
    });

    test('a background run without a worker answers at once', () async {
      await background.start(Future.value());
      final reply = await fromRunner('backgroundRun');
      expect(reply, {'ran': false, 'stopped': true});
    });

    test('the switch reads and writes through the runner', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundChannel, (call) async {
            calls.add(call);
            return {
              'enabled': call.method == 'backgroundSync.set'
                  ? (call.arguments as Map)['enabled']
                  : true,
              'source': call.method == 'backgroundSync.set'
                  ? 'user'
                  : 'default',
            };
          });
      final control = AndroidBackgroundSwitch();
      final state = await control.status();
      expect(state.enabled, isTrue);
      expect(state.source, 'default');
      final off = await control.set(false);
      expect(off.enabled, isFalse);
      expect(off.source, 'user');
    });
  });
}
