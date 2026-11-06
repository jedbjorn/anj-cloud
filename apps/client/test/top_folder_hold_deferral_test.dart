// Flag SC-075: spec #34 P7's delete hold (about 11.5 s after the last loss
// under a top folder) on an event-driven engine, where a missing path is
// first held by the removal deferral (decision #140). A loss counts from
// when it is first seen, deferred or not, so a non-atomic delete that pauses
// longer than the quiet period never sends the earlier losses while the
// folder still exists. From the macOS review probe (mac-int-review,
// p7_hold_deferral_probe); runs with the platform's own watcher (inotify on
// Linux, FSEvents on macOS).
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Rec extends FakeCloud {
  _Rec() {
    foldersQualified = true;
  }
  final deleted = <String>[];
  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    deleted.add(path);
    await super.deleteFile(path, etag: etag);
  }
}

void main() {
  if (!Platform.isLinux && !Platform.isMacOS) {
    test('Linux and macOS only (inotify, FSEvents)', () {}, skip: true);
    return;
  }
  // macOS production values (WatcherSettings defaults): settle = 11.5 s.
  const settings = WatcherSettings(
    quiet: Duration(milliseconds: 1500),
    maxDelay: Duration(seconds: 10),
  );
  late Directory fixture;
  late RootTree tree;
  late _Rec cloud;
  late SyncEngine engine;
  var now = Duration.zero;
  File local(String path) => File('${tree.root.path}/$path');

  setUp(() async {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-probe-')
          .resolveSymbolicLinksSync(),
    );
    // The macOS adapter's verification interval (decision #135) makes the
    // engine event-driven, as it is on macOS.
    tree = RootTree.setup(
      fixture.path,
      'root',
      NativeRootFs(
        null,
        Platform.isMacOS ? 'macOS errno' : 'Linux errno',
        const Duration(minutes: 60),
      ),
    )
      ..vmDirectory = '${fixture.path}/no-vm';
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _Rec();
    for (final d in ['Documents', 'Music', 'Videos']) {
      await cloud.mkdir(d);
    }
    cloud.put('Documents/a.txt', 'alpha');
    cloud.put('Documents/b.txt', 'beta');
    cloud.put('Documents/c.txt', 'gamma');
    engine = SyncEngine(store, tree, cloud)..watcherSettings = settings;
    now = Duration.zero;
    engine.debugElapsed = () => now;
    await engine.startWatching();
    for (var i = 0; i < 40 && !local('Documents/c.txt').existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
    }
    expect(local('Documents/c.txt').existsSync(), isTrue);
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await engine.tick();
    }
    expect(engine.eventDriven, isTrue);
    expect(engine.topDeleteSettle, const Duration(milliseconds: 11500));
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  Future<void> pass(List<String> dirty) async {
    for (final d in dirty) {
      engine.markDirty(d);
    }
    await engine.tick();
  }

  bool held(String p) => engine.manifest.operations.values.any(
    (o) => o.kind == 'delete' && o.path == p,
  );

  test('a loss still held by the deferral restarts the settle', () async {
    local('Documents/a.txt').deleteSync();
    await pass(['Documents/a.txt']);
    expect(held('Documents/a.txt'), isFalse, reason: 'deferred (< quiet)');
    now += settings.quiet;
    await pass(['Documents/a.txt']);
    expect(held('Documents/a.txt'), isTrue, reason: 'inferred and held');
    final t1 = now;
    // The delete goes on 10.5 s later (a pause shorter than the settle).
    now = t1 + const Duration(milliseconds: 10500);
    local('Documents/b.txt').deleteSync();
    await pass(['Documents/b.txt']);
    expect(cloud.deleted, isEmpty);
    now = t1 + const Duration(milliseconds: 11600);
    await pass(['Documents/b.txt']);
    expect(cloud.deleted, isEmpty, reason: 'b restarted the settle');
    expect(held('Documents/a.txt'), isTrue);
  });

  test(
    'with another spelling queued, a loss 2 s later restarts the settle',
    () async {
      local('Documents/a.txt').deleteSync();
      await pass(['Documents/a.txt']);
      now += settings.quiet;
      await pass(['Documents/a.txt']);
      expect(held('Documents/a.txt'), isTrue);
      final t1 = now;
      final w = engine.watcher! as LocalWatcher;
      w.debugNow = () => 0; // the queued spelling never matures
      w.enqueue('Documents/B.txt');
      now = t1 + const Duration(seconds: 2);
      local('Documents/b.txt').deleteSync();
      await pass(['Documents/b.txt']);
      now = t1 + const Duration(milliseconds: 11600);
      await pass(['Documents/b.txt']);
      expect(cloud.deleted, isEmpty, reason: 'b restarted the settle');
      expect(held('Documents/a.txt'), isTrue);
    },
  );

  test('control: the same 10.5 s pause on a full-scan pass holds', () async {
    engine.statAuditInterval = Duration.zero; // every pass a full scan
    local('Documents/a.txt').deleteSync();
    await pass(['Documents/a.txt']);
    expect(held('Documents/a.txt'), isTrue);
    final t1 = now;
    now = t1 + const Duration(milliseconds: 10500);
    local('Documents/b.txt').deleteSync();
    await pass(['Documents/b.txt']);
    now = t1 + const Duration(milliseconds: 11600);
    await pass(['Documents/b.txt']);
    expect(cloud.deleted, isEmpty);
  });
}
