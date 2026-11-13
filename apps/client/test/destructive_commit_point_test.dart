// Decision #137 (1), PR #68 review: with grouped manifest commits (macOS),
// every destructive change to the root waits for a commit point, so its
// record is durable (F_FULLFSYNC) first, whatever the volumes. A fake
// durability records the commits still unflushed at each destructive call
// of the binding and its release guard; each must be zero. Destructive
// sites covered at the boundary, so every caller is included:
//   NativeRootFs.quarantine        (RootTree.quarantine)
//   NativeRootFs.removeEmptyDir    (RootTree removal of empty folders)
//   NativeRootFs.renameExclusive   (SyncEngine.renameLocal)
//   EvictionNative.preserve        (SyncEngine.preserve: a remote deletion
//                                  or replacement keeps the local copy)
//   EvictionNative.quarantine      (Cloud-only release, editing completion)
//   EvictionNative.unlink          (release, staging release, recovery copies)
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/commit_durability.dart';
import 'package:anj_cloud/core/ports/release_guard.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/eviction_native.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Groups implements CommitDurability {
  @override
  void barrier(String path) {}
  @override
  void flush(String path) {}
}

/// (operation, commits not yet flushed when it ran).
typedef _Log = List<(String, int)>;

class _Fs extends NativeRootFs {
  _Fs(this.log) : super(Platform.environment['ANJ_ROOTFS_LIBRARY']);
  final _Log log;
  late Manifest store;
  void _note(String op) => log.add((op, store.unflushedCommits));

  @override
  void quarantine(int fd, String relative, String stage) {
    super.quarantine(fd, relative, stage);
    _note('quarantine');
  }

  @override
  void removeEmptyDir(int fd, String path, String identity) {
    super.removeEmptyDir(fd, path, identity);
    _note('removeEmptyDir');
  }

  @override
  void renameExclusive(int fd, String from, String to, String identity) {
    super.renameExclusive(fd, from, to, identity);
    _note('renameExclusive');
  }

  @override
  ReleaseGuard releaseGuard() => _Guard(this);
}

class _Guard extends EvictionNative {
  _Guard(_Fs super.fs) : owner = fs;
  final _Fs owner;
  @override
  void preserve(int root, String path, int stage, String name) {
    super.preserve(root, path, stage, name);
    owner._note('preserve');
  }

  @override
  void quarantine(int guardFd, int root, String path, int stage, String name) {
    super.quarantine(guardFd, root, path, stage, name);
    owner._note('guard quarantine');
  }

  @override
  void unlink(int guardFd, int stage, String name) {
    super.unlink(guardFd, stage, name);
    owner._note('guard unlink');
  }
}

void main() {
  test('every destructive root change runs after a full flush', () async {
    final fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-destructive-')
          .resolveSymbolicLinksSync(),
    );
    final log = <(String, int)>[];
    final fs = _Fs(log);
    final parent = Directory('${fixture.path}/files')..createSync();
    final tree = RootTree.setup(parent.path, 'root', fs);
    final store = Manifest(
      Directory('${fixture.path}/profile'),
      durability: _Groups(),
    )..setSetting('retention', 'local');
    fs.store = store;
    final cloud = FakeCloud();
    final engine = SyncEngine(store, tree, cloud);
    File local(String path) => File('${tree.root.path}/$path');
    try {
      await engine.tick();
      // Content to work on, synced.
      local('Documents/keep.txt').writeAsStringSync('keep');
      local('Documents/replace.txt').writeAsStringSync('old');
      local('Documents/gone.txt').writeAsStringSync('gone');
      local('Documents/.htaccess').writeAsStringSync('rename');
      Directory('${tree.root.path}/Documents/Empty').createSync();
      local('Archive/blob.bin')
        ..parent.createSync()
        ..writeAsStringSync('release me');
      await engine.tick();
      await engine.tick();
      expect(cloud.files.containsKey('Archive/blob.bin'), isTrue);

      // A remote update (preserve, then install), a remote file deletion
      // (quarantine) and a remote folder deletion (empty-folder removal).
      cloud.put('Documents/replace.txt', 'new');
      cloud.remove('Documents/gone.txt');
      cloud.directories.remove('Documents/Empty');
      await engine.tick();
      await engine.tick();
      // A local rename command.
      await engine.renameLocal('Documents/.htaccess', 'renamed.txt');
      await engine.tick();
      // Cloud-only release (guarded quarantine, then unlink).
      engine.setRetention('Archive', Retention.cloud);
      await engine.tick();
      await engine.tick();

      final ops = {for (final (op, _) in log) op};
      // ignore: avoid_print
      print('destructive calls: $log');
      expect(
        ops,
        containsAll([
          'removeEmptyDir',
          'renameExclusive',
          'preserve',
          'guard quarantine',
          'guard unlink',
        ]),
      );
      for (final (op, unflushed) in log) {
        expect(unflushed, 0, reason: '$op ran with unflushed commits');
      }
      expect(local('Documents/replace.txt').readAsStringSync(), 'new');
      expect(local('Archive/blob.bin').existsSync(), isFalse);
    } finally {
      engine.close();
      fixture.deleteSync(recursive: true);
    }
  });

  test('without the commit-point hook a destructive call would run with '
      'unflushed commits (the check is live)', () async {
    final fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-destructive-')
          .resolveSymbolicLinksSync(),
    );
    final log = <(String, int)>[];
    final fs = _Fs(log);
    final parent = Directory('${fixture.path}/files')..createSync();
    final tree = RootTree.setup(parent.path, 'root', fs);
    final store = Manifest(
      Directory('${fixture.path}/profile'),
      durability: _Groups(),
    )..setSetting('retention', 'local');
    fs.store = store;
    final cloud = FakeCloud();
    final engine = SyncEngine(store, tree, cloud);
    try {
      File('${tree.root.path}/Documents/gone.txt').writeAsStringSync('gone');
      await engine.tick();
      fs.beforeDestructiveChange = null;
      cloud.remove('Documents/gone.txt');
      await engine.tick();
      await engine.tick();
      expect(log, isNotEmpty);
      expect(log.any((e) => e.$2 > 0), isTrue);
    } finally {
      engine.close();
      fixture.deleteSync(recursive: true);
    }
  });
}
