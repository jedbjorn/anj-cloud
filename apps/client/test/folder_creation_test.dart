import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _LostMkdirAcknowledgement extends FakeCloud {
  @override
  Future<void> mkdir(String path) async {
    await super.mkdir(path);
    if (path == 'Uncertain') {
      throw const CloudFailure('mkdir accepted; acknowledgement lost');
    }
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  setUp(() async {
    fixture = Directory.systemTemp.createTempSync('anj-folders-');
    tree = RootTree.setup(
      (Directory('${fixture.path}/files')..createSync()).path,
      'folders',
      NativeRootFs(),
    );
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
    await engine.tick();
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${tree.root.path}/$path');
  void reopen() {
    final root = tree.root.path;
    final staging = tree.staging.path;
    final profile = store.profile;
    engine.close();
    store = Manifest(profile);
    tree = RootTree(Directory(root), Directory(staging), NativeRootFs());
    engine = SyncEngine(store, tree, cloud);
  }

  test('Cloud scaffold accepts OS saves; offline/restart preserves bytes until verified upload', () async {
    cloud.online = false;
    final path = await engine.createFolder(
      '',
      'Cloud notes % λ',
      Retention.cloud,
    );
    expect(Directory('${tree.root.path}/$path').existsSync(), true);
    local('$path/note.txt')
        .writeAsStringSync('saved by an ordinary editor', flush: true);
    await engine.tick();
    expect(
      local('$path/note.txt').readAsStringSync(),
      'saved by an ordinary editor',
    );
    reopen();
    expect(engine.retention('$path/note.txt'), Retention.cloud);
    await engine.tick();
    expect(local('$path/note.txt').existsSync(), true);
    cloud.online = true;
    cloud.failUpload = true;
    await engine.tick();
    expect(local('$path/note.txt').existsSync(), true);
    cloud.failUpload = false;
    await engine.tick();
    expect(
      cloud.files['$path/note.txt'],
      'saved by an ordinary editor'.codeUnits,
    );
    expect(local('$path/note.txt').existsSync(), false);
    expect(Directory('${tree.root.path}/$path').existsSync(), true);
    expect(cloud.deletes, 0);
  });

  test('nested directory overrides and root Local govern every file', () async {
    await engine.createFolder('', 'Cloud', Retention.cloud);
    await engine.createFolder('Cloud', 'Local', Retention.local);
    await engine.createFolder('Cloud/Local', 'Cloud again', Retention.cloud);
    local('root.txt').writeAsStringSync('root');
    local('Cloud/cloud.txt').writeAsStringSync('cloud');
    local('Cloud/Local/local.txt').writeAsStringSync('local');
    local('Cloud/Local/Cloud again/again.txt').writeAsStringSync('again');
    await engine.tick();
    expect(engine.retention('Cloud/Local/local.txt'), Retention.local);
    expect(local('Cloud/Local/local.txt').readAsStringSync(), 'local');
    expect(local('root.txt').readAsStringSync(), 'root');
    expect(local('Cloud/cloud.txt').existsSync(), false);
    expect(local('Cloud/Local/Cloud again/again.txt').existsSync(), false);
    expect(
      () => engine.setRetention('root.txt', Retention.cloud),
      throwsA(isA<FileSystemException>()),
    );
    store.entries['root.txt']!.override = Retention.cloud;
    store.entries['Cloud/Local/local.txt']!.override = Retention.cloud;
    store.save();
    reopen();
    expect(engine.retention('root.txt'), Retention.local);
    expect(engine.retention('Cloud/Local/local.txt'), Retention.local);
    expect(store.entries['root.txt']!.override, isNull);
    expect(store.entries['Cloud/Local/local.txt']!.override, isNull);
  });

  test('rejects collisions, traversal, excluded names and unsupported parents without changing policy', () async {
    local('existing').writeAsStringSync('keep');
    Directory('${tree.root.path}/untracked').createSync();
    Link('${tree.root.path}/link').createSync(fixture.path);
    final outside = Directory('${fixture.path}/outside')..createSync();
    for (final name in [
      'existing',
      'Documents',
      'untracked',
      'link',
      '',
      ' ',
      '.',
      '..',
      '../escape',
      '/escape',
      'a/b',
      r'a\b',
      'a\x00b',
      '.DS_Store',
      'Thumbs.db',
      'desktop.ini',
      '.name.kate-swp',
    ]) {
      await expectLater(
        engine.createFolder('', name, Retention.cloud),
        throwsA(isA<FileSystemException>()),
        reason: name,
      );
    }
    for (final parent in [
      'existing',
      'untracked',
      'link',
      'missing',
      '../outside',
    ]) {
      await expectLater(
        engine.createFolder(parent, 'child', Retention.cloud),
        throwsA(isA<FileSystemException>()),
        reason: parent,
      );
    }
    expect(outside.listSync(), isEmpty);
    expect(local('existing').readAsStringSync(), 'keep');
    expect(store.entries['Documents']!.override, isNull);
    store.entries['Documents']!.expectedPresent = false;
    await expectLater(
      engine.createFolder('Documents', 'child', Retention.cloud),
      throwsA(isA<FileSystemException>()),
    );
    store.entries['Documents']!.expectedPresent = true;
    store.entries['Documents']!.status =
        'deleted remotely; excluded local files retained';
    await expectLater(
      engine.createFolder('Documents', 'child', Retention.cloud),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      store.operations.values.where((op) => op.kind == 'createFolder'),
      isEmpty,
    );
    expect(tree.staging.listSync(), isEmpty);
    final original = tree.root.path;
    tree.root.renameSync('$original-moved');
    Directory(original).createSync();
    await expectLater(
      engine.createFolder('', 'replacement', Retention.cloud),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(original).listSync(), isEmpty);
  });

  test('restart after publish before policy commit keeps ambiguous directory and policy pending', () async {
    store.db.execute(
      "CREATE TRIGGER fail_folder BEFORE INSERT ON entries WHEN NEW.path='Interrupted' BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
    );
    await expectLater(
      engine.createFolder('', 'Interrupted', Retention.cloud),
      throwsA(anything),
    );
    expect(Directory('${tree.root.path}/Interrupted').existsSync(), true);
    expect(store.entries.containsKey('Interrupted'), false);
    expect(
      store.operations.values.where((op) => op.kind == 'createFolder'),
      hasLength(1),
    );
    reopen();
    store.db.execute('DROP TRIGGER fail_folder');
    local('unrelated.txt').writeAsStringSync('keep syncing');
    await engine.tick();
    expect(store.entries.containsKey('Interrupted'), false);
    expect(cloud.files['unrelated.txt'], 'keep syncing'.codeUnits);
    expect(engine.message, contains('needs review after interruption'));
    expect(
      store.operations.values.where((op) => op.kind == 'createFolder'),
      hasLength(1),
    );
    await expectLater(
      engine.createFolder('', 'Interrupted', Retention.local),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.entries.containsKey('Interrupted'), false);
  });

  test('replacement between failed publish and restart never receives the queued policy', () async {
    store.db.execute(
      "CREATE TRIGGER fail_folder BEFORE INSERT ON entries WHEN NEW.path='Interrupted' BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
    );
    await expectLater(
      engine.createFolder('', 'Interrupted', Retention.cloud),
      throwsA(anything),
    );
    Directory('${tree.root.path}/Interrupted')
        .renameSync('${tree.root.path}/original');
    Directory('${tree.root.path}/Interrupted').createSync();
    local('Interrupted/new.txt').writeAsStringSync('unrelated');
    reopen();
    store.db.execute('DROP TRIGGER fail_folder');
    await engine.tick();
    expect(engine.message, contains('needs review after interruption'));
    expect(store.entries.containsKey('Interrupted'), false);
    expect(local('Interrupted/new.txt').readAsStringSync(), 'unrelated');
    expect(engine.retention('Interrupted/new.txt'), Retention.local);
  });

  test('native publication refuses preexisting target, replaced parent and symlink parent', () {
    const staged = 'native-folder';
    tree.native.makeDirExclusive(tree.stageFd, staged);
    final identity = tree.native.directoryIdentity(tree.stageFd, staged);
    final parent = tree.native.directoryIdentity(tree.fd, 'Documents');
    Directory('${tree.root.path}/Documents/collision').createSync();
    expect(
      () => tree.native.installDirectory(
        tree.fd,
        tree.stageFd,
        staged,
        'Documents/collision',
        parent,
        identity,
      ),
      throwsA(isA<FileSystemException>()),
    );
    Directory('${tree.root.path}/Documents')
        .renameSync('${tree.root.path}/moved');
    Directory('${tree.root.path}/Documents').createSync();
    expect(
      () => tree.native.installDirectory(
        tree.fd,
        tree.stageFd,
        staged,
        'Documents/new',
        parent,
        identity,
      ),
      throwsA(isA<FileSystemException>()),
    );
    Directory('${tree.root.path}/Documents').deleteSync();
    Link('${tree.root.path}/Documents').createSync(fixture.path);
    expect(
      () => tree.native.installDirectory(
        tree.fd,
        tree.stageFd,
        staged,
        'Documents/new',
        parent,
        identity,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory('${fixture.path}/new').existsSync(), false);
  });

  test(
    'controller worker serializes offline creation and reports collisions',
    () async {
      final profile = Directory('${fixture.path}/worker-profile');
      final parent = Directory('${fixture.path}/worker-files')..createSync();
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      try {
        await controller.initialize();
        await controller.configureRoot(parent.path);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!controller.canCreateFolder &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(controller.canCreateFolder, true);
        expect(
          await controller.createFolder(
            parent: '',
            name: 'Queued',
            retention: Retention.cloud,
          ),
          'Queued',
        );
        await expectLater(
          controller.createFolder(
            parent: '',
            name: 'Queued',
            retention: Retention.local,
          ),
          throwsA(isA<FileSystemException>()),
        );
        await controller.stop();
        final saved = Manifest(profile);
        expect(saved.entries['Queued']!.override, Retention.cloud);
        expect(Directory('${parent.path}/anj-cloud/Queued').existsSync(), true);
        saved.close();
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );

  test(
    'creation deadline reports uncertainty even if queued creation completes',
    () async {
      final controller = ClientController(
        Directory('${fixture.path}/deadline-profile'),
        secrets: MemorySecrets(),
        folderCommandTimeout: Duration.zero,
        nativeLibrary: testNativeLibrary,
      );
      try {
        await controller.initialize();
        final parent = Directory('${fixture.path}/deadline-files')
          ..createSync();
        await controller.configureRoot(parent.path);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!controller.canCreateFolder &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(controller.canCreateFolder, true);
        await expectLater(
          controller.createFolder(
            parent: '',
            name: 'Maybe created',
            retention: Retention.cloud,
          ),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'uncertainty',
              contains('may have been created'),
            ),
          ),
        );
        await controller.stop();
        final saved = Manifest(controller.profile);
        expect(saved.entries['Maybe created']!.override, Retention.cloud);
        expect(
          Directory('${parent.path}/anj-cloud/Maybe created').existsSync(),
          true,
        );
        saved.close();
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );

  test('lost directory upload acknowledgement cannot adopt a possibly unrelated remote folder', () async {
    cloud = _LostMkdirAcknowledgement();
    engine = SyncEngine(store, tree, cloud);
    await engine.createFolder('', 'Uncertain', Retention.cloud);
    local('Uncertain/local.txt').writeAsStringSync('retained');
    await engine.tick();
    expect(store.entries['Uncertain']!.awaitingFolderUpload, true);
    reopen();
    await engine.tick();
    expect(store.entries['Uncertain']!.conflict, isNotNull);
    expect(local('Uncertain/local.txt').readAsStringSync(), 'retained');
    expect(cloud.files.containsKey('Uncertain/local.txt'), false);
  });

  for (final remoteKind in [ItemKind.directory, ItemKind.file]) {
    test(
      'offline created folder conflicts with unknown remote $remoteKind',
      () async {
        cloud.online = false;
        await engine.createFolder('', 'Collision', Retention.cloud);
        local('Collision/local.txt').writeAsStringSync('local preserved');
        if (remoteKind == ItemKind.directory) {
          cloud.directories.add('Collision');
          cloud.versions['Collision'] = '"existing-directory"';
          cloud.put('Collision/remote.txt', 'remote preserved');
        } else {
          cloud.put('Collision', 'remote preserved');
        }
        cloud.online = true;
        await engine.tick();
        expect(store.entries['Collision']!.conflict, isNotNull);
        expect(
          local('Collision/local.txt').readAsStringSync(),
          'local preserved',
        );
        expect(cloud.files.containsKey('Collision/local.txt'), false);
        expect(
          String.fromCharCodes(
            cloud.files[remoteKind == ItemKind.directory
                ? 'Collision/remote.txt'
                : 'Collision']!,
          ),
          'remote preserved',
        );
        expect(cloud.deletes, 0);
      },
    );
  }

  for (final phase in ['after-intent', 'after-publish', 'after-commit']) {
    test('real process restart recovers folder creation $phase', () async {
      final target = '${fixture.path}/crash-$phase';
      final dart = testDartExecutable;
      final crashed = await Process.run(dart, [
        'run',
        'tool/folder_creation_fixture.dart',
        target,
        phase,
      ]);
      expect(
        crashed.exitCode,
        86,
        reason: '${crashed.stdout} ${crashed.stderr}',
      );
      final persisted = Manifest(Directory('$target/profile'));
      expect(persisted.entries.containsKey('Created'), phase == 'after-commit');
      expect(
        persisted.operations.values.where((op) => op.kind == 'createFolder'),
        hasLength(phase == 'after-commit' ? 0 : 1),
      );
      persisted.close();
      final resumed = await Process.run(dart, [
        'run',
        'tool/folder_creation_fixture.dart',
        target,
        phase == 'after-publish' ? 'resume-pending' : 'resume',
      ]);
      expect(
        resumed.exitCode,
        0,
        reason: '${resumed.stdout} ${resumed.stderr}',
      );
    });
  }
}
