// Decision #130 (3) and (4), spec #28 A2: what Android adds to the shared
// event-driven hashing of event_driven_hashing_test.dart (decision #135):
// its 15-minute adapter, the watch-limit verification, the verification when
// the app opens (and only there) and the interrupted-install leftover. Runs on
// Linux with the Android adapters over the Linux build of the same anj_* ABI;
// the on-device run is integration_test/android_engine_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/artifacts.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Android's filesystem adapter with a short verification interval.
class _ShortVerification extends AndroidRootFs {
  _ShortVerification(this.interval)
    : super(Platform.environment['ANJ_ROOTFS_LIBRARY']);
  Duration interval;
  @override
  Duration? get fullVerificationInterval => interval;
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
          .createTempSync('anj-android-hash-')
          .resolveSymbolicLinksSync(),
    );
    fs = _ShortVerification(const Duration(minutes: 15));
    tree = RootTree.setup(fixture.path, 'events', fs);
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    for (var i = 0; i < 20; i++) {
      local('Documents/f$i.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $i');
    }
    engine = await open(
      () => SyncEngine(
        store,
        tree,
        cloud,
        watchers: const AndroidChangeWatchers(),
      ),
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

  test('the watch limit fallback verifies once, then audits by stat', () async {
    await engine.tick();
    await quiesce();
    watcher().native.watchDebugFailAdds(watcher().handle, 'Documents/Full');
    Directory('${tree.root.path}/Documents/Full/a').createSync(recursive: true);
    local('Documents/Full/a/x.txt').writeAsStringSync('x');
    await pump(() => remote('Documents/Full/a/x.txt') == 'x');
    expect(watcher().exhausted, greaterThan(0));
    await engine.tick();
    expect(engine.fullVerifications, 2);
    final after = engine.fullVerifications;
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(engine.fullVerifications, after, reason: 'not repeated per pass');
  });

  test('the app opening verifies every file; a desktop window shown does '
      'not', () async {
    engine.close();
    closed = true;
    Future<int> verificationsAfter(Map<String, Object> shown) async {
      final value = await open(
        () => SyncEngine(
          Manifest(Directory('${fixture.path}/profile')),
          RootTree(tree.root, tree.staging, fs),
          cloud,
          watchers: const AndroidChangeWatchers(),
        ),
      );
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        value,
        (_) {},
        interval: const Duration(milliseconds: 100),
        schedule: RemoteSchedule(idle: const Duration(seconds: 30)),
      );
      final done = loop.run(input.stream);
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (value.lastPass == null || value.lastPass!.filesHashed != 0) {
        if (DateTime.now().isAfter(end)) fail('did not settle');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final before = value.fullVerifications;
      input.add(shown);
      await Future<void>.delayed(const Duration(seconds: 1));
      input.add({'action': 'stop'});
      await done;
      await input.close();
      // The loop closed the engine when it stopped.
      return value.fullVerifications - before;
    }

    expect(
      await verificationsAfter({'action': 'visible', 'verify': true}),
      1,
      reason: 'Android entry: the app opened',
    );
    expect(
      await verificationsAfter({'action': 'visible'}),
      0,
      reason: 'desktop window shown (#135)',
    );
  });

  test('no back-to-back timer passes while nothing changed', () async {
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

    final android = await open(
      () => SyncEngine(
        Manifest(Directory('${fixture.path}/profile')),
        RootTree(tree.root, tree.staging, fs),
        cloud,
        watchers: const AndroidChangeWatchers(),
      ),
    );
    final idle = await passesIn(android, const Duration(seconds: 2));
    expect(idle, lessThanOrEqualTo(1), reason: 'quiet: wait for the listing');

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
  });

  group('interrupted install (decision #130 (4))', () {
    test('a leftover copy is removed at start; a recorded name is kept', () {
      engine.close();
      closed = true;
      final stage = tree.staging.path;
      final leftover = '${Artifacts.installTempPrefix}4242-0';
      final recorded = '${Artifacts.installTempPrefix}4242-1';
      File('$stage/$leftover').writeAsStringSync('half a copy');
      File('$stage/$recorded').writeAsStringSync('named by a record');
      File('$stage/download-x').writeAsStringSync('not an install copy');
      final again = Manifest(Directory('${fixture.path}/profile'));
      final op = Operation(
        uniqueId(),
        'artifact',
        'Documents/r.txt',
        staged: '$stage/$recorded',
        phase: 'reserved',
      )..data = {'role': 'download', 'name': recorded};
      again.operations[op.id] = op;
      again.save();
      final reopened = RootTree(tree.root, tree.staging, fs);
      // Before the cleanup the leftover makes staging uncertain, which
      // holds back Cloud release.
      expect(Artifacts(again, reopened).hasLegacyOrUncertain, isTrue);
      final probe = SyncEngine(again, reopened, cloud);
      expect(probe.interruptedInstalls, [leftover]);
      expect(File('$stage/$leftover').existsSync(), isFalse);
      expect(File('$stage/$recorded').existsSync(), isTrue);
      expect(File('$stage/download-x').existsSync(), isTrue);
      probe.close();
    });

    test('with only a leftover, staging is certain again after start', () {
      engine.close();
      closed = true;
      File('${tree.staging.path}/${Artifacts.installTempPrefix}1-0')
          .writeAsStringSync('x');
      final again = Manifest(Directory('${fixture.path}/profile'));
      final reopened = RootTree(tree.root, tree.staging, fs);
      expect(Artifacts(again, reopened).hasLegacyOrUncertain, isTrue);
      final probe = SyncEngine(again, reopened, cloud);
      expect(probe.interruptedInstalls, hasLength(1));
      expect(probe.artifacts.hasLegacyOrUncertain, isFalse);
      probe.close();
    });
  });
}
