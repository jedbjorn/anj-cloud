import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Server-qualified folder deletion: removes exactly the named subtree.
class _FolderCloud extends FakeCloud {
  @override
  bool get safeFolderDeletion => true;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    check();
    for (final key in files.keys.toList()) {
      if (key == path || p.posix.isWithin(path, key)) remove(key);
    }
    directories.removeWhere((d) => d == path || p.posix.isWithin(path, d));
    this.versions.removeWhere((d, _) => d == path || p.posix.isWithin(path, d));
  }
}

/// The PUT lands, but its response omits the version; another writer
/// replaces the file before the version is read back separately.
class _ReadBackCloud extends FakeCloud {
  String? raceText;
  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    await super.upload(path, source, etag: etag);
    lastUploadReadBack = true;
    if (raceText != null) {
      put(path, raceText!);
      raceText = null;
    }
    return versions[path]!;
  }
}

/// Spec #12 (decision #37): redundant staging copies are released only when
/// the server provably holds the same bytes; everything else is retained.
void main() {
  const dir = 'Documents/issue/run';
  const pending =
      'Reconciled. Busy or uncertain Cloud releases remain pending.';
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;

  Future<void> boot(FakeCloud fake) async {
    engine.close();
    fixture.deleteSync(recursive: true);
    fixture = Directory.systemTemp.createTempSync('anj-staging-release-');
    tree = RootTree.setup(
      (Directory('${fixture.path}/files')..createSync()).path,
      'release',
      NativeRootFs(),
    );
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = fake;
    engine = SyncEngine(store, tree, cloud);
    tree.ensureDirectory(dir);
    await engine.tick();
    // Documents itself is never Cloud-only (spec #34 P7).
    engine.setRetention('Documents/issue', Retention.cloud);
    await engine.tick();
    engine.setRetention(dir, Retention.local);
    await engine.tick();
  }

  void restart() {
    final rootPath = tree.root.path;
    final stagePath = tree.staging.path;
    engine.close();
    tree = RootTree(Directory(rootPath), Directory(stagePath), NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    engine = SyncEngine(store, tree, cloud);
  }

  setUp(() async {
    // Same layout as the b35f858 field reproduction: a Local and Cloud folder
    // inside a Cloud-only folder.
    fixture = Directory.systemTemp.createTempSync('anj-staging-release-');
    tree = RootTree.setup(
      (Directory('${fixture.path}/files')..createSync()).path,
      'release',
      NativeRootFs(),
    );
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
    tree.ensureDirectory(dir);
    await engine.tick();
    // Documents itself is never Cloud-only (spec #34 P7).
    engine.setRetention('Documents/issue', Retention.cloud);
    await engine.tick();
    engine.setRetention(dir, Retention.local);
    await engine.tick();
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String name) => File('${tree.root.path}/$dir/$name');
  List<String> staged(String prefix) => tree.staging
      .listSync()
      .map((f) => p.basename(f.path))
      .where((name) => name.startsWith(prefix))
      .toList();
  Iterable<Operation> records(String path, [String? role]) =>
      engine.artifacts.records.where(
        (o) =>
            (o.data['entryPath'] ?? o.path) == path &&
            (role == null || o.data['role'] == role),
      );
  Iterable<Operation> retained(String path) => store.operations.values.where(
    (o) => o.kind == 'retained' && o.path == path,
  );
  Future<Map<String, dynamic>> project(String path) async =>
      Map<String, dynamic>.from(
        await projectEntry(engine, store.entries[path]!),
      );
  Future<List<LibraryRow>> rows() async => libraryRows(
    [
      for (final entry in store.entries.values)
        Map<String, dynamic>.from(await projectEntry(engine, entry)),
    ],
    LibraryTab.home,
    {},
  );
  Future<void> uploaded(String name, String text) async {
    local(name).writeAsStringSync(text, flush: true);
    await engine.tick();
    expect(String.fromCharCodes(cloud.files['$dir/$name']!), text);
  }

  test(
    'three uploads in a Local and Cloud folder leave no upload snapshot',
    () async {
      for (var i = 0; i < 3; i++) {
        await uploaded('acc.txt', 'rev$i' * 10);
        expect(staged('upload-'), isEmpty);
      }
      expect(records('$dir/acc.txt', 'upload'), isEmpty);
      expect(local('acc.txt').readAsStringSync(), 'rev2' * 10);
      expect(store.entries['$dir/acc.txt']!.status, 'current local');
      expect(cloud.counter, greaterThanOrEqualTo(3));
      expect(engine.message, 'Reconciled.');
    },
  );

  test(
    'an upload with an unknown outcome keeps its snapshot and record',
    () async {
      cloud.loseNextUploadAcknowledgement = true;
      local('acc.txt')
          .writeAsStringSync('accepted, unacknowledged', flush: true);
      await engine.tick();
      final upload = store.operations.values.singleWhere(
        (o) => o.kind == 'upload',
      );
      final snapshot = records('$dir/acc.txt', 'upload').single;
      expect(snapshot.staged, upload.staged);
      expect(snapshot.expectedEtag, isNull);
      expect(staged('upload-'), [p.basename(upload.staged!)]);
      expect(
        File(upload.staged!).readAsStringSync(),
        'accepted, unacknowledged',
      );
      // The next pass proves the version by hash; only then is it released.
      await engine.tick();
      expect(store.operations.values.any((o) => o.kind == 'upload'), isFalse);
      expect(staged('upload-'), isEmpty);
      expect(records('$dir/acc.txt'), isEmpty);
      expect(local('acc.txt').readAsStringSync(), 'accepted, unacknowledged');
    },
  );

  test('single and bulk Delete Everywhere release identical copies; rows disappear', () async {
    for (final name in ['b.txt', 'c.txt', 'd.txt']) {
      await uploaded(name, name[0] * 40);
    }
    Map<String, dynamic> target(String path) => {
      'path': path,
      'kind': 'file',
      'selectionVersion': engine.selectionVersion(store.entries[path]!),
    };
    expect(
      engine.applyBulk('delete', [
        target('$dir/b.txt'),
        target('$dir/c.txt'),
      ])['accepted'],
      2,
    );
    engine.requestDelete('$dir/d.txt');
    await engine.tick();
    for (final name in ['b.txt', 'c.txt', 'd.txt']) {
      final path = '$dir/$name';
      expect(cloud.files.containsKey(path), isFalse);
      expect(local(name).existsSync(), isFalse);
      expect(store.entries[path]!.status, 'deleted');
      expect(store.entries[path]!.preservedCopies, isEmpty);
      expect(retained(path), isEmpty);
      expect(records(path), isEmpty);
      final projection = await project(path);
      expect(hasQueuedWork(projection), isFalse);
      expect(visibleInLibrary(projection), isFalse);
    }
    expect(staged('preserved-'), isEmpty);
    expect(staged('upload-'), isEmpty);
    final library = await rows();
    expect(library.where((r) => r.path.endsWith('.txt')), isEmpty);
    expect(library.where((r) => r.attention), isEmpty);
    expect(engine.message, 'Reconciled.');
    await engine.tick();
    expect(cloud.deletes, 3);
  });

  test(
    'a deleted copy that differs from the deleted version is a Recovery copy',
    () async {
      await uploaded('b.txt', 'uploaded version');
      engine.requestDelete('$dir/b.txt');
      local('b.txt').writeAsStringSync('edited after upload', flush: true);
      for (var pass = 0; pass < 2; pass++) {
        await engine.tick();
        expect(cloud.files.containsKey('$dir/b.txt'), isFalse);
        final copy = retained('$dir/b.txt').single;
        expect(File(copy.staged!).readAsStringSync(), 'edited after upload');
        expect(records('$dir/b.txt', 'preserved').single.staged, copy.staged);
        expect(staged('preserved-'), [p.basename(copy.staged!)]);
        final projection = await project('$dir/b.txt');
        expect(projection['status'], 'deleted');
        expect(fileBadge(projection), 'Recovery copy');
        expect(hasQueuedWork(projection), isFalse);
        if (pass == 1) {
          // The established late-edit guard still offers recovery as new files.
          expect(projection['conflict'], isNotNull);
          expect(projection['canRecoverLocalVariants'], isTrue);
        }
        final library = await rows();
        expect(
          library.where((r) => r.attention).map((r) => r.path),
          containsAll(['Documents', 'Documents/issue', dir, '$dir/b.txt']),
        );
      }
    },
  );

  test(
    'a deleted copy is retained when the deleted version hash is unknown',
    () async {
      await uploaded('b.txt', 'uploaded version');
      // No hash recorded for this version: neither on the entry nor in records.
      store.entries['$dir/b.txt']!
        ..remoteHash = null
        ..remoteHashEtag = null;
      store.save();
      expect(records('$dir/b.txt'), isEmpty);
      engine.requestDelete('$dir/b.txt');
      await engine.tick();
      await engine.tick();
      final copy = retained('$dir/b.txt').single;
      expect(copy.data['deletedVersionHash'], isNull);
      expect(File(copy.staged!).readAsStringSync(), 'uploaded version');
      expect(fileBadge(await project('$dir/b.txt')), 'Recovery copy');
    },
  );

  test(
    'a copy busy at release time is retained and reported until it is free',
    () async {
      await uploaded('b.txt', 'uploaded version');
      final reader = local('b.txt').openSync();
      try {
        engine.requestDelete('$dir/b.txt');
        await engine.tick();
        expect(retained('$dir/b.txt'), hasLength(1));
        expect(staged('preserved-'), hasLength(1));
        expect(engine.message, pending);
        expect(fileBadge(await project('$dir/b.txt')), 'Recovery copy');
      } finally {
        reader.closeSync();
      }
      await engine.tick();
      expect(retained('$dir/b.txt'), isEmpty);
      expect(staged('preserved-'), isEmpty);
      expect(engine.message, 'Reconciled.');
    },
  );

  test(
    'a copy modified between hash and unlink keeps its bytes and record',
    () async {
      await uploaded('b.txt', 'uploaded version');
      final trigger = File('${fixture.path}/trigger');
      final child = await Process.start('python3', [
        '-c',
        'import os,sys,time; p=sys.argv[1]\nwhile not os.path.exists(p): time.sleep(.002)\npath=open(p).read();f=os.open(path,os.O_WRONLY|os.O_TRUNC);os.write(f,b"raced writer bytes");os.close(f)',
        trigger.path,
      ]);
      var broken = false;
      engine.releases.barrier = (point, record, fd) {
        if (point != 'before-unlink' || record.data['role'] != 'preserved') {
          return;
        }
        trigger.writeAsStringSync(record.staged!);
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline)) {
          try {
            engine.artifacts.native.valid(fd);
          } on FileSystemException {
            broken = true;
            break;
          }
          sleep(const Duration(milliseconds: 1));
        }
      };
      engine.requestDelete('$dir/b.txt');
      await engine.tick();
      expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
      engine.releases.barrier = null;
      expect(broken, isTrue);
      for (var pass = 0; pass < 2; pass++) {
        final copy = retained('$dir/b.txt').single;
        expect(File(copy.staged!).readAsStringSync(), 'raced writer bytes');
        expect(records('$dir/b.txt', 'preserved').single.staged, copy.staged);
        expect(cloud.files.containsKey('$dir/b.txt'), isFalse);
        await engine.tick();
      }
    },
  );

  test(
    'existing profiles converge: the Laptop b/c deletion state is released',
    () async {
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        await uploaded(name, name[0] * 40);
      }
      // Rebuild the state written by b35f858: every upload left a confirmed
      // upload-* snapshot, and Delete Everywhere preserved each file without
      // recorded deletion facts. Earlier manifests hold no entry version hash.
      for (final name in ['a.txt', 'b.txt', 'c.txt']) {
        final path = '$dir/$name';
        final entry = store.entries[path]!;
        final snapshot = engine.artifacts.reserve(path, 'upload');
        final hash = tree.snapshotFile(path, snapshot);
        engine.artifacts.complete(snapshot, hash: hash, etag: entry.etag);
        entry
          ..remoteHash = null
          ..remoteHashEtag = null;
        if (name == 'a.txt') continue;
        engine.preserve(entry);
        entry
          ..expectedPresent = false
          ..etag = null
          ..status = 'deleted';
        cloud.remove(path);
      }
      store.save();
      final rootPath = tree.root.path;
      final stagePath = tree.staging.path;
      engine.close();
      tree = RootTree(
        Directory(rootPath),
        Directory(stagePath),
        NativeRootFs(),
      );
      store = Manifest(Directory('${fixture.path}/profile'));
      engine = SyncEngine(store, tree, cloud);
      expect(staged('preserved-'), hasLength(2));
      expect(staged('upload-'), hasLength(3));
      for (final name in ['b.txt', 'c.txt']) {
        final projection = await project('$dir/$name');
        expect(fileBadge(projection), 'Recovery copy');
        expect(hasQueuedWork(projection), isFalse);
      }
      await engine.tick();
      expect(staged('preserved-'), isEmpty);
      expect(staged('upload-'), isEmpty);
      for (final name in ['b.txt', 'c.txt']) {
        expect(retained('$dir/$name'), isEmpty);
        expect(records('$dir/$name'), isEmpty);
        expect(visibleInLibrary(await project('$dir/$name')), isFalse);
      }
      final library = await rows();
      expect(library.map((r) => r.path), contains('$dir/a.txt'));
      expect(library.map((r) => r.path), isNot(contains('$dir/b.txt')));
      expect(library.map((r) => r.path), isNot(contains('$dir/c.txt')));
      expect(library.where((r) => r.attention), isEmpty);
      expect(local('a.txt').readAsStringSync(), 'a' * 40);
      expect(store.entries['$dir/a.txt']!.status, 'current local');
      expect(String.fromCharCodes(cloud.files['$dir/a.txt']!), 'a' * 40);
      expect(engine.message, 'Reconciled.');
    },
  );

  test(
    'artifact detail counts kinds and sizes hard-linked inodes once',
    () async {
      cloud.put('$dir/x.txt', 'x' * 40);
      await engine.tick();
      cloud.put('$dir/x.txt', 'y' * 50);
      await engine.tick();
      expect(local('x.txt').readAsStringSync(), 'y' * 50);
      final artifacts = engine.localArtifacts('$dir/x.txt');
      if (!tree.native.hardLinks) {
        // Android renames both downloads into place (decision #123 (2)): only
        // the preserved version (40) and the check snapshot (40) stay.
        expect(artifacts['count'], 2);
        expect(artifacts['kinds'], {'recovery': 1, 'check': 1});
        expect(artifacts['bytes'], 80);
        return;
      }
      // download-1 and preserved-* share the replaced inode (40), check-* is a
      // separate pre-replacement snapshot (40) and download-2 is the root
      // file's inode (50). Four names, three inodes: 130 bytes, not 170.
      expect(artifacts['count'], 4);
      expect(artifacts['kinds'], {'download': 2, 'recovery': 1, 'check': 1});
      expect(artifacts['bytes'], 130);
      expect(
        artifactSummary(await project('$dir/x.txt')),
        'Local staging files: recovery 1, download 2, check 1 (130 bytes)',
      );
      expect(jsonEncode(artifacts['files']), contains('"kind":"recovery"'));
    },
  );

  group('review fixes', () {
    test(
      '1: folder Delete Everywhere releases identical descendant copies',
      () async {
        await boot(_FolderCloud());
        tree.ensureDirectory('$dir/sub');
        await engine.tick();
        File('${tree.root.path}/$dir/sub/k.txt').writeAsStringSync('k' * 30);
        await engine.tick();
        expect(cloud.files.containsKey('$dir/sub/k.txt'), isTrue);
        engine.requestDelete('$dir/sub');
        await engine.tick();
        await engine.tick();
        expect(cloud.files.containsKey('$dir/sub/k.txt'), isFalse);
        expect(Directory('${tree.root.path}/$dir/sub').existsSync(), isFalse);
        final child = store.entries['$dir/sub/k.txt']!;
        expect(child.status, 'deleted remotely');
        expect(child.preservedCopies, isEmpty);
        expect(retained('$dir/sub/k.txt'), isEmpty);
        expect(staged('preserved-'), isEmpty);
        final projection = await project('$dir/sub/k.txt');
        expect(hasQueuedWork(projection), isFalse);
        expect(visibleInLibrary(projection), isFalse);
        expect((await rows()).where((r) => r.attention), isEmpty);
        expect(engine.message, 'Reconciled.');
      },
    );

    test(
      '1: a deletion made on another device releases an identical copy',
      () async {
        await uploaded('r.txt', 'r' * 30);
        cloud.remove('$dir/r.txt');
        await engine.tick();
        expect(local('r.txt').existsSync(), isFalse);
        final entry = store.entries['$dir/r.txt']!;
        expect(entry.status, 'deleted remotely');
        expect(retained('$dir/r.txt'), isEmpty);
        expect(records('$dir/r.txt'), isEmpty);
        expect(staged('preserved-'), isEmpty);
        expect(visibleInLibrary(await project('$dir/r.txt')), isFalse);
        expect(engine.message, 'Reconciled.');
      },
    );

    test('1: a file updated from another device, then deleted there, releases its deleted-version copy', () async {
      await uploaded('u.txt', 'ours v1');
      cloud.put('$dir/u.txt', 'their v2');
      await engine.tick();
      expect(local('u.txt').readAsStringSync(), 'their v2');
      cloud.remove('$dir/u.txt');
      await engine.tick();
      final contents = tree.staging
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .toList();
      // The deleted version's bytes (v2: copy and hard-linked download-*)
      // are released; the replacement copy of v1 differs from the deleted
      // version and is retained as a recovery copy.
      expect(contents, isNot(contains('their v2')));
      final kept = retained('$dir/u.txt').single;
      expect(File(kept.staged!).readAsStringSync(), 'ours v1');
      expect(kept.data['deletion'], isNull);
      final projection = await project('$dir/u.txt');
      expect(fileBadge(projection), 'Recovery copy');
      expect(hasQueuedWork(projection), isFalse);
    });

    test('1: a file updated from another device, then Delete Everywhere here, releases the deleted version', () async {
      cloud.put('$dir/x.txt', 'x' * 40);
      await engine.tick();
      cloud.put('$dir/x.txt', 'y' * 50);
      await engine.tick();
      engine.requestDelete('$dir/x.txt');
      await engine.tick();
      expect(cloud.files.containsKey('$dir/x.txt'), isFalse);
      final names = staged('');
      expect(
        names.map((n) => File(p.join(tree.staging.path, n)).readAsStringSync()),
        isNot(contains('y' * 50)),
      );
      final deletion = retained('$dir/x.txt')
          .where((o) => o.data['deletion'] == true);
      expect(deletion, isEmpty);
      // Only the replacement copy of the superseded version remains.
      expect(
        File(retained('$dir/x.txt').single.staged!).readAsStringSync(),
        'x' * 40,
      );
    });

    test(
      '2: a remote file already gone before our delete keeps its copy',
      () async {
        await uploaded('o.txt', 'our v1');
        engine.requestDelete('$dir/o.txt');
        cloud.put('$dir/o.txt', 'other device v2');
        cloud.remove('$dir/o.txt');
        await engine.tick();
        await engine.tick();
        expect(cloud.deletes, 0);
        final copy = retained('$dir/o.txt').single;
        expect(copy.data['deletedVersion'], isNull);
        expect(copy.data['deletedVersionHash'], isNull);
        expect(File(copy.staged!).readAsStringSync(), 'our v1');
        final projection = await project('$dir/o.txt');
        expect(projection['status'], 'deleted');
        expect(fileBadge(projection), 'Recovery copy');
        expect(engine.message, 'Reconciled.');
      },
    );

    test('2: descendants of a folder already gone before our delete keep their copies', () async {
      await boot(_FolderCloud());
      tree.ensureDirectory('$dir/sub');
      await engine.tick();
      File('${tree.root.path}/$dir/sub/k.txt').writeAsStringSync('k' * 30);
      await engine.tick();
      engine.requestDelete('$dir/sub');
      await cloud.deleteFolder('$dir/sub', versions: const {});
      await engine.tick();
      final copy = retained('$dir/sub/k.txt').single;
      expect(copy.data['deletion'], isTrue);
      expect(copy.data['deletedVersionHash'], isNull);
      await engine.tick();
      expect(File(copy.staged!).readAsStringSync(), 'k' * 30);
      expect(fileBadge(await project('$dir/sub/k.txt')), 'Recovery copy');
      // The unobserved-deletion marker is dropped once nothing can use it.
      expect(store.setting('unknownDeletedFoldersV1'), isNull);
    });

    test(
      '3: a version read back separately is never release evidence',
      () async {
        final racing = _ReadBackCloud();
        await boot(racing);
        racing.raceText = 'other writer bytes';
        local('h.txt').writeAsStringSync('ours', flush: true);
        await engine.tick();
        final entry = store.entries['$dir/h.txt']!;
        expect(entry.etag, cloud.versions['$dir/h.txt']);
        expect(entry.remoteHashEtag, isNull);
        expect(entry.remoteHash, isNull);
        // Rule 1: the version was not recorded, so the snapshot is kept.
        final snapshot = records('$dir/h.txt', 'upload').single;
        expect(snapshot.data['versionReadBack'], isTrue);
        expect(File(snapshot.staged!).readAsStringSync(), 'ours');
        engine.requestDelete('$dir/h.txt');
        await engine.tick();
        final copy = retained('$dir/h.txt').single;
        expect(copy.data['deletedVersionHash'], isNull);
        expect(File(copy.staged!).readAsStringSync(), 'ours');
        expect(fileBadge(await project('$dir/h.txt')), 'Recovery copy');
      },
    );

    test('4: a stale release intent is cleared when the copy changed after a crash', () async {
      await uploaded('b.txt', 'uploaded version');
      engine.releases.barrier = (point, record, fd) {
        if (point == 'before-unlink' && record.data['role'] == 'preserved') {
          throw StateError('simulated crash');
        }
      };
      engine.requestDelete('$dir/b.txt');
      await expectLater(engine.tick(), throwsStateError);
      restart();
      final copy = retained('$dir/b.txt').single;
      Operation record() =>
          engine.artifacts.records.singleWhere((o) => o.staged == copy.staged);
      expect(record().data['releasing'], isNotNull);
      final handle = File(copy.staged!).openSync(mode: FileMode.writeOnly);
      handle.writeStringSync('changed after crash');
      handle.truncateSync('changed after crash'.length);
      handle.closeSync();
      await engine.tick();
      await engine.tick();
      expect(File(copy.staged!).readAsStringSync(), 'changed after crash');
      expect(retained('$dir/b.txt'), hasLength(1));
      expect(record().data.containsKey('releasing'), isFalse);
      expect(fileBadge(await project('$dir/b.txt')), 'Recovery copy');
    });

    for (final known in [true, false]) {
      test(
        '5: an interrupted preserve converges (deleted version ${known ? 'known' : 'unknown'})',
        () async {
          await uploaded('b.txt', 'uploaded version');
          const path = '$dir/b.txt';
          final entry = store.entries[path]!;
          engine.requestDelete(path);
          await cloud.deleteFile(path, etag: entry.etag!);
          // acknowledgeDelete's preserve, interrupted after the rename and
          // before the record was completed or the retained op written.
          final op = engine.intent(path, 'preserve', etag: entry.etag);
          op.data.addAll(
            engine.deletionFacts(entry, known ? entry.etag : null),
          );
          final target = engine.artifacts.reserve(
            path,
            'preserved',
            create: false,
          );
          op.staged = tree.durablePath(target);
          op.hash = entry.baselineHash;
          store.save();
          engine.artifacts.native.preserve(
            tree.fd,
            path,
            tree.stageFd,
            p.basename(target.path),
          );
          restart();
          await engine.tick();
          expect(store.entries[path]!.status, 'deleted');
          expect(engine.message, 'Reconciled.');
          if (known) {
            expect(retained(path), isEmpty);
            expect(records(path), isEmpty);
            expect(staged('preserved-'), isEmpty);
          } else {
            final copy = retained(path).single;
            expect(File(copy.staged!).readAsStringSync(), 'uploaded version');
            final record = records(path, 'preserved').single;
            expect(record.phase, 'complete');
            expect(record.data['identity'], isNotNull);
            await engine.tick();
            expect(engine.message, 'Reconciled.');
            expect(retained(path), hasLength(1));
          }
        },
      );
    }
  });

  for (final phase in ['before-unlink', 'after-unlink-before-db']) {
    test('a real process crash at $phase converges with no copy lacking a record', () async {
      final path = '${fixture.path}/crash-$phase';
      final dart = testDartExecutable;
      final crashed = await Process.run(dart, [
        'run',
        'tool/staging_release_fixture.dart',
        path,
        phase,
      ]);
      expect(
        crashed.exitCode,
        86,
        reason: '${crashed.stdout}\n${crashed.stderr}',
      );
      final interrupted = Manifest(Directory('$path/profile'));
      try {
        final copy = interrupted.operations.values.singleWhere(
          (o) => o.kind == 'artifact' && o.data['role'] == 'preserved',
        );
        // Verified intent is durable before unlink; the record survives it.
        expect(copy.data['releasing'], isNotNull);
        expect(File(copy.staged!).existsSync(), phase == 'before-unlink');
      } finally {
        interrupted.close();
      }
      final resumed = await Process.run(dart, [
        'run',
        'tool/staging_release_fixture.dart',
        path,
        'resume',
      ]);
      expect(
        resumed.exitCode,
        0,
        reason: '${resumed.stdout}\n${resumed.stderr}',
      );
      final result =
          jsonDecode(File('$path/result.json').readAsStringSync()) as Map;
      expect(result['status'], 'deleted');
      expect(result['remote_present'], isFalse);
      expect(result['root_present'], isFalse);
      expect(result['staged'], isEmpty);
      expect(result['unrecorded'], isEmpty);
      expect(result['records'], isEmpty);
      expect(result['retained'], 0);
      expect(result['preserved_copies'], isEmpty);
      expect(result['message'], 'Reconciled.');
    });
  }
}
