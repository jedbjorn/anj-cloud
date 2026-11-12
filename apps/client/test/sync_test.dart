import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/evictions.dart' show openedCopyKept;
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';

void main() {
  // Deletions under Documents here are not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  RootTree newTree(String name) {
    final parent = Directory('${fixture.path}/$name')..createSync();
    return RootTree.setup(parent.path, name, NativeRootFs());
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-client-test-');
    tree = newTree('a');
    store = Manifest(Directory('${fixture.path}/profile-a'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${tree.root.path}/$path');
  Future<void> baseline([String path = 'Documents/note.txt']) async {
    local(path).writeAsStringSync('original');
    await engine.tick();
  }

  test(
    'recursively uploads arbitrary nested folders and modified files',
    () async {
      tree.ensureDirectory('Music/Albums/Deep');
      final file = local('Music/Albums/Deep/track.txt')
        ..writeAsStringSync('first');
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Music/Albums/Deep/track.txt']!),
        'first',
      );
      file.writeAsStringSync('second');
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Music/Albums/Deep/track.txt']!),
        'second',
      );
    },
  );
  test(
    'offline filesystem deletion survives restart and uses old version',
    () async {
      await baseline();
      local('Documents/note.txt').deleteSync();
      cloud.online = false;
      await engine.tick();
      expect(store.operations.values.any((o) => o.kind == 'delete'), isTrue);
      engine.close();
      store = Manifest(Directory('${fixture.path}/profile-a'));
      tree = RootTree(
        Directory('${fixture.path}/a/anj-cloud'),
        Directory('${fixture.path}/a/.anj-cloud-a'),
        NativeRootFs(),
      );
      cloud.online = true;
      engine = SyncEngine(store, tree, cloud);
      await engine.tick();
      expect(cloud.files.containsKey('Documents/note.txt'), isFalse);
      expect(cloud.deletes, 1);
    },
  );
  test('remote recursive deletion clears metadata and removes only empty local directories', () async {
    tree.ensureDirectory('Documents/Gone/Nested');
    local('Documents/Gone/Nested/child.txt')
        .writeAsStringSync('safe retained bytes');
    await engine.tick();
    await engine.tick();
    cloud.files.removeWhere((path, _) => path.startsWith('Documents/Gone/'));
    cloud.directories.removeWhere(
      (path) => path == 'Documents/Gone' || path.startsWith('Documents/Gone/'),
    );
    cloud.versions.removeWhere(
      (path, _) =>
          path == 'Documents/Gone' || path.startsWith('Documents/Gone/'),
    );
    await engine.tick();
    expect(Directory('${tree.root.path}/Documents/Gone').existsSync(), isFalse);
    expect(store.entries['Documents/Gone']!.etag, isNull);
    final child = store.entries['Documents/Gone/Nested/child.txt']!;
    // Spec #12 rule 2: the preserved copy equals the hash this client
    // recorded for the deleted version, so it is released, not retained.
    expect(child.status, 'deleted remotely');
    expect(child.preservedCopies, isEmpty);
    expect(
      tree.staging.listSync().where(
        (f) => f.path.split('/').last.startsWith('preserved-'),
      ),
      isEmpty,
    );
    await engine.tick();
    expect(cloud.directories.contains('Documents/Gone'), isFalse);
    expect(
      cloud.files.keys.any((path) => path.startsWith('Documents/Gone/')),
      isFalse,
    );
  });
  test('remote deleted folder with a new local descendant preserves tree and never uploads it', () async {
    tree.ensureDirectory('Documents/Gone');
    await engine.tick();
    await engine.tick();
    cloud.directories.remove('Documents/Gone');
    cloud.versions.remove('Documents/Gone');
    local('Documents/Gone/new.txt').writeAsStringSync('unuploaded');
    await engine.tick();
    await engine.tick();
    expect(local('Documents/Gone/new.txt').readAsStringSync(), 'unuploaded');
    expect(store.entries['Documents/Gone']!.conflict, isNotNull);
    expect(cloud.files.containsKey('Documents/Gone/new.txt'), isFalse);
  });
  test('empty directory removal refuses changed identity, unknown contents and symlink parents', () async {
    tree.ensureDirectory('Documents/Nonempty');
    local('Documents/Nonempty/unknown.txt').writeAsStringSync('keep');
    final identity = (await tree.snapshot())['Documents/Nonempty']!.identity!;
    expect(
      () => tree.removeEmptyDirectory('Documents/Nonempty', identity),
      throwsA(isA<FileSystemException>()),
    );
    tree.ensureDirectory('Documents/Empty');
    expect(
      () => tree.removeEmptyDirectory('Documents/Empty', identity),
      throwsA(isA<FileSystemException>()),
    );
    final outside = Directory('${fixture.path}/outside')..createSync();
    Directory('${outside.path}/empty').createSync();
    Link('${tree.root.path}/Documents/alias').createSync(outside.path);
    expect(
      () => tree.removeEmptyDirectory('Documents/alias/empty', identity),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory('${outside.path}/empty').existsSync(), isTrue);
    expect(local('Documents/Nonempty/unknown.txt').readAsStringSync(), 'keep');
  });
  test('opening a cloud-only file is not editing; a changed working copy is pinned with a truthful Cloud pending status', () async {
    // Documents itself never takes the legacy Cloud choice (spec #34 P7).
    store.setSetting('retention', 'cloud');
    cloud.put('Library/open.txt', 'remote bytes');
    await engine.tick();
    final path = await engine.openFile('Library/open.txt');
    expect(File(path).readAsStringSync(), 'remote bytes');
    expect(local('Library/open.txt').existsSync(), isFalse);
    await engine.tick();
    // Decisions #183/#184: an unchanged copy is not an edit; the Cloud row
    // explains the opened copy it keeps.
    expect(store.entries['Library/open.txt']!.status, openedCopyKept);
    File(path).writeAsStringSync('edited bytes', flush: true);
    await engine.tick();
    expect(
      store.entries['Library/open.txt']!.status,
      contains('Cloud pending'),
    );
    expect(store.entries['Library/open.txt']!.status, contains('pinned'));
    expect(File(path).readAsStringSync(), 'edited bytes');
  });
  test('delete/edit conflict retains changed remote bytes', () async {
    await baseline();
    local('Documents/note.txt').deleteSync();
    cloud.put('Documents/note.txt', 'remote edit');
    await engine.tick();
    expect(cloud.deletes, 0);
    expect(
      store.entries['Documents/note.txt']!.conflict,
      contains('Delete/edit'),
    );
    expect(
      String.fromCharCodes(cloud.files['Documents/note.txt']!),
      'remote edit',
    );
  });
  test(
    'remote deletion never automatically reuploads dirty local content',
    () async {
      await baseline();
      local('Documents/note.txt').writeAsStringSync('local edit');
      cloud.remove('Documents/note.txt');
      await engine.tick();
      await engine.tick();
      expect(cloud.files.containsKey('Documents/note.txt'), isFalse);
      expect(local('Documents/note.txt').readAsStringSync(), 'local edit');
      expect(store.entries['Documents/note.txt']!.conflict, isNotNull);
    },
  );
  test(
    'simultaneous edits preserve local and complete remote conflict copy',
    () async {
      await baseline();
      local('Documents/note.txt').writeAsStringSync('local edit');
      cloud.put('Documents/note.txt', 'remote edit');
      await engine.tick();
      final e = store.entries['Documents/note.txt']!;
      expect(e.conflict, isNotNull);
      expect(local(e.path).readAsStringSync(), 'local edit');
      expect(File(e.remoteCopy!).readAsStringSync(), 'remote edit');
    },
  );
  test('missing root pauses without creating mass-deletion intents', () async {
    await baseline();
    tree.root.renameSync('${fixture.path}/a/moved');
    await engine.tick();
    expect(engine.message, contains('Paused'));
    expect(store.operations.values.any((o) => o.kind == 'delete'), isFalse);
    expect(cloud.deletes, 0);
  });
  test(
    'symlinks are listed unsupported without reading their targets',
    () async {
      final outside = File('${fixture.path}/outside')
        ..writeAsStringSync('outside private bytes');
      Link('${tree.root.path}/escape').createSync(outside.path);
      await engine.tick();
      expect(store.entries['escape']!.kind, ItemKind.unsupported);
      expect(cloud.files.containsKey('escape'), isFalse);
      expect(outside.readAsStringSync(), 'outside private bytes');
    },
  );
  test('native installation refuses overwrite and symlink parent', () async {
    final stage = tree.newStagedFile()..writeAsStringSync('incoming');
    local('Documents/existing').writeAsStringSync('keep');
    expect(
      () => tree.installAbsent('Documents/existing', stage),
      throwsA(isA<FileSystemException>()),
    );
    expect(local('Documents/existing').readAsStringSync(), 'keep');
    final outside = Directory('${fixture.path}/outside')..createSync();
    Link('${tree.root.path}/link').createSync(outside.path);
    expect(
      () => tree.installAbsent('link/new', stage),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('${outside.path}/new').existsSync(), isFalse);
  });
  test('failed uploads preserve source and do not advance baseline', () async {
    local('Documents/note.txt').writeAsStringSync('pending');
    cloud.failUpload = true;
    await engine.tick();
    expect(local('Documents/note.txt').readAsStringSync(), 'pending');
    expect(store.entries['Documents/note.txt']!.baselineHash, isNull);
    expect(store.operations.values.any((o) => o.kind == 'upload'), isTrue);
  });
  test(
    'Cloud releases proven clean local bytes without remote deletion',
    () async {
      // Documents itself is never Cloud-only (spec #34 P7).
      tree.ensureDirectory('Documents/Cloud');
      await baseline('Documents/Cloud/note.txt');
      engine.setRetention('Documents/Cloud', Retention.cloud);
      await engine.tick();
      expect(local('Documents/Cloud/note.txt').existsSync(), isFalse);
      expect(cloud.deletes, 0);
      expect(
        String.fromCharCodes(cloud.files['Documents/Cloud/note.txt']!),
        'original',
      );
      expect(store.entries['Documents/Cloud/note.txt']!.status, 'cloud-only');
      expect(store.operations.values.any((o) => o.kind == 'evict'), isFalse);
      expect(tree.staging.listSync(), isEmpty);
      await engine.tick();
      expect(cloud.deletes, 0);
    },
  );
  test('second Cloud profile sees recursive entries without fake placeholder files', () async {
    // Documents itself never takes the legacy Cloud choice (spec #34 P7).
    tree.ensureDirectory('Library');
    await baseline('Library/note.txt');
    final b = newTree('b');
    final db = Manifest(Directory('${fixture.path}/profile-b'));
    db.setSetting('retention', 'cloud');
    final second = SyncEngine(db, b, cloud);
    try {
      await second.tick();
      expect(db.entries['Library/note.txt']!.status, 'cloud-only');
      expect(File('${b.root.path}/Library/note.txt').existsSync(), isFalse);
    } finally {
      second.close();
    }
  });
  test(
    'working copy edits synchronize without root reverting them later',
    () async {
      await baseline();
      final opened = File(await engine.openFile('Documents/note.txt'));
      opened.writeAsStringSync('editor change');
      await engine.tick();
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Documents/note.txt']!),
        'editor change',
      );
      expect(local('Documents/note.txt').readAsStringSync(), 'editor change');
    },
  );
  test(
    'folder deletion stays pending before server concurrency qualification',
    () async {
      // An ordinary folder: deleting Documents itself is never sent
      // (spec #34 P7).
      tree.ensureDirectory('Library');
      await baseline('Library/note.txt');
      await engine.tick();
      Directory('${tree.root.path}/Library').deleteSync(recursive: true);
      await engine.tick();
      expect(cloud.files.containsKey('Library/note.txt'), isTrue);
      expect(
        store.entries['Library']!.status,
        contains('awaiting server proof'),
      );
      expect(cloud.deletes, 0);
    },
  );
  test('interrupted preserve recovers as internal absence rather than external deletion', () async {
    await baseline();
    final e = store.entries['Documents/note.txt']!;
    final preserved = tree.newStagedFile('crash');
    final op = Operation(
      uniqueId(),
      'preserve',
      e.path,
      expectedEtag: e.etag,
      staged: preserved.path,
    );
    store.operations[op.id] = op;
    store.save();
    tree.native.quarantine(tree.fd, e.path, preserved.path);
    await engine.tick();
    expect(cloud.deletes, 0);
    expect(preserved.readAsStringSync(), 'original');
    expect(e.preservedCopies, contains(preserved.path));
    expect(local(e.path).readAsStringSync(), 'original');
  });
  test('late writes through an open descriptor remain preserved and become conflicts', () async {
    await baseline();
    final held = local('Documents/note.txt').openSync(mode: FileMode.append);
    try {
      cloud.put('Documents/note.txt', 'remote replacement');
      await engine.tick();
      held.writeStringSync(' late local edit');
      held.flushSync();
      await engine.tick();
      final entry = store.entries['Documents/note.txt']!;
      expect(entry.conflict, contains('preserved local version changed'));
      expect(
        entry.preservedCopies
            .map((path) => File(path).readAsStringSync())
            .any((text) => text.contains('late local edit')),
        isTrue,
      );
      expect(local(entry.path).readAsStringSync(), 'remote replacement');
    } finally {
      held.closeSync();
    }
  });
  test('Keep both forks late preserved edits rather than duplicating the clean remote version', () async {
    await baseline();
    final held = local('Documents/note.txt').openSync(mode: FileMode.append);
    try {
      cloud.put('Documents/note.txt', 'remote replacement');
      await engine.tick();
      held.writeStringSync(' late edit');
      held.flushSync();
      await engine.tick();
      await engine.keepBoth('Documents/note.txt');
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Documents/note.txt']!),
        'remote replacement',
      );
      expect(
        cloud.files.entries.any(
          (e) =>
              e.key.contains('.conflict-') &&
              String.fromCharCodes(e.value).contains('late edit'),
        ),
        isTrue,
      );
      expect(store.entries['Documents/note.txt']!.conflict, isNull);
    } finally {
      held.closeSync();
    }
  });
  test('explicit Delete everywhere preserves then removes the local source and never resurrects it', () async {
    await baseline();
    final held = local('Documents/note.txt').openSync(mode: FileMode.append);
    try {
      engine.requestDelete('Documents/note.txt');
      await engine.tick();
      expect(local('Documents/note.txt').existsSync(), isFalse);
      expect(cloud.files.containsKey('Documents/note.txt'), isFalse);
      held.writeStringSync(' late editor write');
      held.flushSync();
      await engine.tick();
      expect(cloud.files.containsKey('Documents/note.txt'), isFalse);
      final entry = store.entries['Documents/note.txt']!;
      expect(entry.conflict, isNotNull);
      expect(
        entry.preservedCopies
            .map((path) => File(path).readAsStringSync())
            .any((text) => text.contains('late editor write')),
        isTrue,
      );
    } finally {
      held.closeSync();
    }
  });
  test(
    'lost upload acknowledgement clears its intent before a later edit',
    () async {
      cloud.loseNextUploadAcknowledgement = true;
      local('Documents/note.txt').writeAsStringSync('first accepted');
      await engine.tick();
      expect(store.operations.values.any((op) => op.kind == 'upload'), isTrue);
      await engine.tick();
      expect(store.operations.values.any((op) => op.kind == 'upload'), isFalse);
      local('Documents/note.txt').writeAsStringSync('second edit');
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Documents/note.txt']!),
        'second edit',
      );
      expect(store.entries['Documents/note.txt']!.conflict, isNull);
    },
  );
  test(
    'a newer local edit is preserved across interrupted-upload recovery',
    () async {
      await baseline();
      cloud.loseNextUploadAcknowledgement = true;
      local('Documents/note.txt')
          .writeAsStringSync('accepted before lost acknowledgement');
      await engine.tick();
      local('Documents/note.txt').writeAsStringSync('newer local edit');
      await engine.tick();
      expect(
        String.fromCharCodes(cloud.files['Documents/note.txt']!),
        'newer local edit',
      );
      expect(store.entries['Documents/note.txt']!.conflict, isNull);
      expect(store.operations.values.any((op) => op.kind == 'upload'), isFalse);
    },
  );
  test('sync engine refuses persisted root/profile overlap before scanning SQLite files', () {
    final nested = Manifest(
      Directory('${tree.root.path}/nested-private-profile'),
    );
    try {
      expect(
        () => SyncEngine(nested, tree, cloud),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      nested.close();
    }
  });
  test('interrupted upload conflict keeps a durable remote copy across worker restart', () async {
    cloud.loseNextUploadAcknowledgement = true;
    local('Documents/note.txt').writeAsStringSync('local accepted bytes');
    await engine.tick();
    cloud.put('Documents/note.txt', 'different remote bytes');
    await engine.tick();
    final copy = store.entries['Documents/note.txt']!.remoteCopy!;
    expect(copy, startsWith(tree.staging.path));
    expect(copy.contains('/proc/self/fd/'), isFalse);
    for (final table in ['entries', 'operations']) {
      for (final row in store.db.select('SELECT body FROM $table')) {
        expect((row['body'] as String).contains('/proc/self/fd/'), isFalse);
      }
    }
    engine.close();
    store = Manifest(Directory('${fixture.path}/profile-a'));
    tree = RootTree(
      Directory('${fixture.path}/a/anj-cloud'),
      Directory('${fixture.path}/a/.anj-cloud-a'),
      NativeRootFs(),
    );
    engine = SyncEngine(store, tree, cloud);
    final recovered = store.entries['Documents/note.txt']!;
    expect(recovered.conflict, isNotNull);
    expect(
      File(recovered.remoteCopy!).readAsStringSync(),
      'different remote bytes',
    );
    expect(local(recovered.path).readAsStringSync(), 'local accepted bytes');
  });
}
