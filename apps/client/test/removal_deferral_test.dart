// PR #68 review: event-driven passes (decision #135) defer inferring a local
// removal so a case- or normalization-only rename can pair (decision #138).
// A fake clock (SyncEngine.debugElapsed) drives the three bounds: with no
// other side the removal follows after the quiet period; with another
// spelling queued it waits, but never past the maximum delay; a full scan
// or stat audit decides at once.
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const settings = WatcherSettings(
    quiet: Duration(milliseconds: 150),
    maxDelay: Duration(seconds: 2),
  );
  late Directory fixture;
  late RootTree tree;
  late FakeCloud cloud;
  late SyncEngine engine;
  var now = Duration.zero;

  File local(String path) => File('${tree.root.path}/$path');
  bool removed() =>
      !(engine.manifest.entries['Docs/a.txt']?.expectedPresent ?? false);

  setUp(() async {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-deferral-')
          .resolveSymbolicLinksSync(),
    );
    tree = RootTree.setup(
      fixture.path,
      'root',
      NativeRootFs(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
        'Linux errno',
        const Duration(minutes: 60),
      ),
    )..vmDirectory = '${fixture.path}/no-vm';
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(
      store,
      tree,
      cloud,
      watchers: const LinuxChangeWatchers(),
    )..watcherSettings = settings;
    now = Duration.zero;
    engine.debugElapsed = () => now;
    await engine.startWatching();
    local('Docs/a.txt')
      ..parent.createSync()
      ..writeAsStringSync('a');
    for (var i = 0; i < 40 && cloud.files['Docs/a.txt'] == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
    }
    expect(cloud.files['Docs/a.txt'], isNotNull);
    expect(engine.eventDriven, isTrue);
    // Let the upload's own events settle.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
    }
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  test('no other side: the removal follows after the quiet period', () async {
    local('Docs/a.txt').deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.tick();
    expect(engine.lastPass!.localScan, 'partial');
    expect(removed(), isFalse, reason: 'missing for less than quiet');
    now += settings.quiet;
    await engine.tick();
    expect(removed(), isTrue);
  });

  test(
    'another spelling queued: it waits, but not past the maximum delay',
    () async {
      final w = engine.watcher! as LocalWatcher;
      w.debugNow = () => 0; // The watcher's queue never matures.
      w.enqueue('Docs/A.txt'); // A case-only spelling of the vanished path.
      local('Docs/a.txt').deleteSync();
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(removed(), isFalse);
      now += settings.quiet * 4;
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(removed(), isFalse, reason: 'past quiet, the spelling is queued');
      now += settings.maxDelay;
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(removed(), isTrue, reason: 'capped at the maximum delay');
    },
  );

  test('a full scan (the stat audit) decides at once', () async {
    local('Docs/a.txt').deleteSync();
    engine.statAuditInterval = Duration.zero;
    await engine.tick();
    expect(engine.lastPass!.localScan, 'full');
    expect(removed(), isTrue, reason: 'no deferral, no clock advance');
  });
}
