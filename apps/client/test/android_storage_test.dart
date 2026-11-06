// PR #60 review findings F1 and F2 (decisions #123 (2), #130 (3)).
//
// F1: an ordinary install keeps no second copy in staging, after downloads
// and after the file is deleted elsewhere. Run with the Linux library (the
// staging name is a free hard link) and with the host build of the Android
// boundary (ANJ_ROOTFS_LIBRARY=<-DANJ_ANDROID_BOUNDARY build>,
// ANJ_ROOTFS_HARDLINKS=0: installs rename); tool/check.sh runs both.
//
// F2: with event-driven hashing (Android adapters) a paused observation never
// reads file content.
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory fixture;
  setUp(() => fixture = Directory.systemTemp.createTempSync('anj-storage-'));
  tearDown(() => fixture.deleteSync(recursive: true));

  /// Bytes in staging whose inode is not also a root file.
  int stagingOnly(SyncEngine engine) {
    final tree = engine.tree;
    final root = <String>{
      for (final item in tree.native.scan(tree.fd))
        if (item['kind'] == 'file') "${item['volume']}:${item['inode']}",
    };
    var bytes = 0;
    final seen = <String>{};
    for (final item in tree.native.scan(tree.stageFd)) {
      if (item['kind'] != 'file') continue;
      final id = "${item['volume']}:${item['inode']}";
      if (seen.add(id) && !root.contains(id)) bytes += item['size'] as int;
    }
    return bytes;
  }

  test('F1: downloads leave no bytes in staging beyond the root', () async {
    final fs = NativeRootFs();
    final tree = RootTree.setup(fixture.path, 'f1', fs);
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    final cloud = FakeCloud();
    final engine = SyncEngine(store, tree, cloud);
    try {
      const size = 1 << 20;
      for (var i = 0; i < 5; i++) {
        cloud.put('Music/t$i.bin', String.fromCharCode(97 + i) * size);
      }
      for (var i = 0; i < 4; i++) {
        await engine.tick();
      }
      for (var i = 0; i < 5; i++) {
        expect(
          File('${tree.root.path}/Music/t$i.bin').lengthSync(),
          size,
          reason: 'installed',
        );
      }
      expect(stagingOnly(engine), 0, reason: 'hardLinks=${fs.hardLinks}');
      // Deleted on another device: no staged bytes of it remain either.
      cloud.remove('Music/t0.bin');
      cloud.remove('Music/t2.bin');
      for (var i = 0; i < 3; i++) {
        await engine.tick();
      }
      expect(File('${tree.root.path}/Music/t0.bin').existsSync(), isFalse);
      expect(stagingOnly(engine), 0);
      // Updated there, then deleted there: the replaced local version stays
      // as a recovery copy by design (with its check snapshot), but nothing
      // of the deleted version does (the review's 'their v2' case).
      cloud.put('Music/t1.bin', 'their v2');
      await engine.tick();
      cloud.remove('Music/t1.bin');
      for (var i = 0; i < 3; i++) {
        await engine.tick();
      }
      final kept = [
        for (final f in tree.staging.listSync().whereType<File>())
          f.readAsStringSync(),
      ];
      expect(kept, isNot(contains('their v2')));
      if (!fs.hardLinks) {
        // Android: only those two copies of version 1, nothing else.
        expect(stagingOnly(engine), 2 * size);
      }
      expect(engine.message, 'Reconciled.');
    } finally {
      engine.close();
    }
  });

  test('F2: a paused observation hashes nothing (event-driven)', () async {
    final fs = AndroidRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']);
    final tree = RootTree.setup(fixture.path, 'f2', fs);
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    for (var i = 0; i < 20; i++) {
      File('${tree.root.path}/Documents/f$i.txt')
          .writeAsStringSync('f$i' * 100);
    }
    final engine = SyncEngine(
      store,
      tree,
      FakeCloud(),
      watchers: const AndroidChangeWatchers(),
    );
    try {
      await engine.startWatching();
      (engine.watcher! as LocalWatcher)
        ..quiet = const Duration(milliseconds: 100)
        ..maxDelay = const Duration(seconds: 1);
      for (var i = 0; i < 4; i++) {
        await engine.tick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(engine.eventDriven, isTrue);
      final before = fs.meter.files;
      expect(await engine.observePaused(), 0);
      expect(await engine.observePaused(), 0);
      expect(fs.meter.files - before, 0, reason: 'idle paused checks');
      // A change while paused is counted from stat and events, not content.
      File('${tree.root.path}/Documents/f3.txt').writeAsStringSync('edited');
      File('${tree.root.path}/Documents/new.txt').writeAsStringSync('new');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await engine.observePaused(), greaterThanOrEqualTo(2));
      expect(fs.meter.files - before, 0, reason: 'still no reads');
    } finally {
      engine.close();
    }
  });

  test('F1: a rename install interrupted by a restart is finished', () {
    final fs = NativeRootFs();
    final tree = RootTree.setup(fixture.path, 'moves', fs);
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    Operation record(String name) {
      final op = Operation(
        uniqueId(),
        'artifact',
        'Music/$name',
        staged: '${tree.staging.path}/$name',
        phase: 'complete',
      )..data = {'role': 'download', 'name': name, 'installing': 'Music/$name'};
      store.operations[op.id] = op;
      return op;
    }

    // Renamed before the crash: the staged name is gone.
    final moved = record('download-moved');
    // Not renamed yet: the staged file is still there.
    final pending = record('download-pending');
    File('${tree.staging.path}/download-pending').writeAsStringSync('bytes');
    pending.data
      ..['identity'] = fs
          .releaseGuard()
          .info(tree.stageFd, 'download-pending')
          .identity
      ..['directoryIdentity'] = fs.identity(tree.stageFd);
    store.save();
    final engine = SyncEngine(store, tree, FakeCloud());
    try {
      expect(store.operations.containsKey(moved.id), isFalse);
      expect(
        store.operations[pending.id]!.data.containsKey('installing'),
        isFalse,
      );
      expect(engine.artifacts.hasLegacyOrUncertain, isFalse);
    } finally {
      engine.close();
    }
  });
}
