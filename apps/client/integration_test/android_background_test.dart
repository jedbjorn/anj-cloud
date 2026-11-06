// Spec #28 A4 on the VM host emulator (seat E), inside the real runner: the
// `cloud.anj/background` channel, the dataSync service and notifications
// (Kotlin), and "Wi-Fi only" driven by the emulator's real default-network
// changes (NetworkMonitor) into a WorkerLoop over a fake cloud. The payload
// script tool/android/emu_background.sh toggles Wi-Fi at the `ANJ-A4 net-*`
// markers and reads dumpsys at the `ANJ-A4 notify-*` markers, then creates
// `files/a4-go-<step>` (run-as) to let the test continue.
//
// A gateway is not used: the emulator cannot pair before A3 lands, so the
// network rows against R stay pending (see the PR).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/android/background.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/fakes.dart';

void say(String line) {
  // ignore: avoid_print
  print('ANJ-A4 $line');
}

class _CountingCloud extends FakeCloud {
  int listings = 0;
  int downloads = 0;
  @override
  Future<List<RemoteItem>> snapshot() {
    listings++;
    return super.snapshot();
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    downloads++;
    return super.download(path, target, etag: etag);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory files;
  late Map attach;
  bool? wifi;
  final reports = StreamController<bool>.broadcast();

  Future<void> go(String step) async {
    final marker = File('${files.path}/a4-go-$step');
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (!marker.existsSync()) {
      if (DateTime.now().isAfter(end)) fail('no go for $step');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<void> until(
    bool Function() done,
    String what, {
    int seconds = 90,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    files = Directory(
      (await getApplicationSupportDirectory()).resolveSymbolicLinksSync(),
    );
    backgroundChannel.setMethodCallHandler((call) async {
      if (call.method == 'network') {
        wifi = (call.arguments as Map)['wifi'] == true;
        say('network wifi=$wifi');
        reports.add(wifi!);
      }
      return null;
    });
    attach = (await backgroundChannel.invokeMethod<Map>('attach'))!;
    wifi = attach['wifi'] as bool?;
    say('attach $attach');
  });

  test('progress through the dataSync service, attention, cleared', () async {
    await backgroundChannel.invokeMethod('transfers', {
      'count': 3,
      'waiting': 0,
    });
    await backgroundChannel.invokeMethod('attention', {
      'items': [
        {
          'key': 'conflict:Docs/a.txt:x',
          'path': 'Docs/a.txt',
          'title': 'Conflict: a.txt',
          'text': 'Both versions changed. Complete copies are retained.',
        },
        {
          'key': 'refused:Video/big.mov:x',
          'path': 'Video/big.mov',
          'title': 'Upload refused: big.mov',
          'text': 'Too large for the server (64 MB limit)',
        },
      ],
    });
    say('notify-posted notifications=${attach['notifications']}');
    await go('notify');
    // The queue drained, with files left waiting for Wi-Fi.
    await backgroundChannel.invokeMethod('transfers', {
      'count': 0,
      'waiting': 2,
    });
    say('notify-cleared');
    await go('cleared');
  });

  test(
    'background runs: one full verification; paused hashes nothing',
    () async {
      final fixture = Directory('${files.path}/a4-runs');
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      fixture.createSync();
      final tree = RootTree.setup(fixture.path, 'runs', AndroidRootFs());
      for (var i = 0; i < 10; i++) {
        File('${tree.root.path}/Docs/f$i.txt')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('file $i');
      }
      final store = Manifest(Directory('${fixture.path}/profile'))
        ..setSetting('retention', 'local');
      final cloud = _CountingCloud();
      final gate = PausableCloud(cloud);
      final engine = SyncEngine(
        store,
        tree,
        gate,
        watchers: const AndroidChangeWatchers(),
      );
      await engine.startWatching();
      final events = <Map>[];
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        engine,
        (event) => events.add(event as Map),
        gate: gate,
        schedule: RemoteSchedule(idle: const Duration(seconds: 60)),
      );
      final done = loop.run(input.stream);
      Map? reply(String id) => events
          .where((e) => e['event'] == 'backgroundDone' && e['request'] == id)
          .firstOrNull;
      try {
        await until(() => cloud.files.length == 10, 'initial upload');
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(engine.eventDriven, isTrue);
        final before = engine.fullVerifications;
        input.add({'action': 'background', 'request': 'run'});
        await until(() => reply('run') != null, 'background reply');
        expect(engine.fullVerifications, before + 1);
        expect(
          engine.lastPass!.filesHashedBy['scan'],
          greaterThanOrEqualTo(10),
        );
        input.add({'action': 'pause'});
        await Future<void>.delayed(const Duration(seconds: 1));
        final hashed = tree.native.meter.files;
        final verifications = engine.fullVerifications;
        final listings = cloud.listings;
        input.add({'action': 'background', 'request': 'paused'});
        await until(() => reply('paused') != null, 'paused reply');
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(reply('paused')!['paused'], isTrue);
        expect(tree.native.meter.files - hashed, 0);
        expect(engine.fullVerifications, verifications);
        expect(cloud.listings, listings);
        say(
          'runs full-verifications=${engine.fullVerifications - before} '
          'paused-hashed=${tree.native.meter.files - hashed} '
          'paused-listings=${cloud.listings - listings}',
        );
      } finally {
        input.add({'action': 'stop'});
        await done;
        await input.close();
      }
    },
  );

  test('Wi-Fi only: bytes wait on mobile data, listings do not', () async {
    if (attach['notifications'] != true) {
      say('net-skipped (notification-denied run)');
      return;
    }
    final fixture = Directory('${files.path}/a4-net')..createSync();
    for (final child in fixture.listSync()) {
      child.deleteSync(recursive: true);
    }
    final tree = RootTree.setup(fixture.path, 'net', AndroidRootFs());
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    final cloud = _CountingCloud();
    final gate = PausableCloud(cloud);
    final engine = SyncEngine(
      store,
      tree,
      gate,
      watchers: const AndroidChangeWatchers(),
    );
    await engine.startWatching();
    final input = StreamController<Object?>();
    final loop = WorkerLoop(
      engine,
      (_) {},
      gate: gate,
      schedule: RemoteSchedule(idle: const Duration(seconds: 3)),
      defaultNetworkPolicy: 'wifi',
    );
    final done = loop.run(input.stream);
    final forward = reports.stream.listen(
      (value) => input.add({'action': 'network', 'wifi': value}),
    );
    File local(String path) => File('${tree.root.path}/$path');
    String? remote(String path) {
      final bytes = cloud.files[path];
      return bytes == null ? null : utf8.decode(bytes);
    }

    try {
      input.add({'action': 'network', 'wifi': wifi});
      expect(wifi, isTrue, reason: 'the emulator starts on Wi-Fi');
      say('net-ready');
      await until(() => wifi == false, 'Wi-Fi disabled');
      local('Docs/a.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('local a');
      cloud.put('Music/song.txt', 'remote song');
      final listings = cloud.listings;
      await until(() => cloud.listings >= listings + 2, 'two listings');
      await until(
        () =>
            store.entries['Docs/a.txt']?.status == waitingForWifiStatus &&
            store.entries['Music/song.txt']?.status == waitingForWifiStatus,
        'both waiting',
      );
      expect(cloud.uploadAttempts, 0);
      expect(cloud.downloads, 0);
      expect(gate.heldTransfers, 0, reason: 'the engine checks first');
      say(
        'net-held listings=${cloud.listings - listings} uploads=${cloud.uploadAttempts} '
        'downloads=${cloud.downloads} waiting=${engine.waitingForNetwork.length}',
      );
      await until(() => wifi == true, 'Wi-Fi enabled');
      await until(
        () =>
            remote('Docs/a.txt') == 'local a' &&
            local('Music/song.txt').existsSync(),
        'released transfers',
      );
      say('net-released uploads=${cloud.uploads} downloads=${cloud.downloads}');
      await until(() => wifi == false, 'Wi-Fi disabled again');
      local('Docs/b.txt').writeAsStringSync('local b');
      await until(
        () => store.entries['Docs/b.txt']?.status == waitingForWifiStatus,
        'b waiting',
      );
      input.add({'action': 'networkPolicy', 'value': 'any'});
      await until(
        () => remote('Docs/b.txt') == 'local b',
        'b over mobile data',
      );
      say(
        'net-any uploaded-on-cellular=true policy=${store.setting('network')}',
      );
    } finally {
      await forward.cancel();
      input.add({'action': 'stop'});
      await done;
      await input.close();
    }
  });
}
