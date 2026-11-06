import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _Cloud extends FakeCloud {
  int downloads = 0;
  bool incompleteSnapshot = false;
  void Function()? afterSnapshot;
  @override
  Future<List<RemoteItem>> snapshot() async {
    final result = await super.snapshot();
    afterSnapshot?.call();
    if (incompleteSnapshot) throw const CloudFailure('incomplete listing');
    return result;
  }

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async {
    downloads++;
    await super.download(path, target, etag: etag);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-root-policy-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'root-policy', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = _Cloud();
    engine = SyncEngine(store, tree, cloud);
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
    tree = RootTree(Directory(root), Directory(staging), NativeRootFs());
    store = Manifest(profile);
    engine = SyncEngine(store, tree, cloud);
  }

  test('new root and nested additions sync with fixed Local default', () async {
    local('root.txt').writeAsStringSync('root');
    tree.ensureDirectory('Documents/Deep');
    local('Documents/Deep/nested.txt').writeAsStringSync('nested');
    await engine.tick();
    expect(engine.defaultRetention, Retention.local);
    expect(engine.retention(''), Retention.local);
    expect(engine.retention('.'), Retention.local);
    expect(cloud.files['root.txt'], 'root'.codeUnits);
    expect(cloud.files['Documents/Deep/nested.txt'], 'nested'.codeUnits);
    expect(local('root.txt').existsSync(), true);
    cloud.put('remote.txt', 'new remote');
    await engine.tick();
    expect(local('remote.txt').readAsStringSync(), 'new remote');
  });

  test('folder choices preserve explicit child directory overrides and new children upload before release', () async {
    // An ordinary folder: Documents, Music and Videos are never Cloud-only
    // (spec #34 P7).
    tree.ensureDirectory('Library/Local');
    local('Library/Local/keep.txt').writeAsStringSync('keep');
    await engine.tick();
    engine.setRetention('Library/Local', Retention.local);
    engine.setRetention('Library', Retention.cloud);
    local('Library/new.txt').writeAsStringSync('new');
    cloud.online = false;
    await engine.tick();
    expect(local('Library/new.txt').readAsStringSync(), 'new');
    cloud.online = true;
    await engine.tick();
    expect(cloud.files['Library/new.txt'], 'new'.codeUnits);
    expect(local('Library/new.txt').existsSync(), false);
    expect(local('Library/Local/keep.txt').readAsStringSync(), 'keep');
    expect(engine.retention('Library/Local/keep.txt'), Retention.local);
    expect(cloud.deletes, 0);
    local('Library/Local/keep.txt').deleteSync();
    await engine.tick();
    expect(cloud.files.containsKey('Library/Local/keep.txt'), false);
    expect(cloud.deletes, 1);
  });

  test('controller and engine refuse root aliases for storage and deletion even with a legacy root row', () {
    final controller = ClientController(
      store.profile,
      secrets: MemorySecrets(),
      nativeLibrary: testNativeLibrary,
    );
    for (final path in ['', '.', '/', './', 'Documents/..', tree.root.path]) {
      store.entries[path] = Entry(path, ItemKind.directory)..etag = '"root"';
      for (final action in ['retention', 'delete']) {
        expect(
          () => controller.command(action, path, value: 'cloud'),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(
        () => engine.setRetention(path, Retention.cloud),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => engine.requestDelete(path),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.entries[path]!.override, null);
    }
    expect(store.operations, isEmpty);
    controller.dispose();
  });

  test('old Cloud root becomes bounded overrides with no broad download; later top-level additions stay Local', () async {
    store.setSetting('retention', 'cloud');
    store.entries['Documents'] = Entry('Documents', ItemKind.directory);
    store.entries['Documents/keep.txt'] = Entry(
      'Documents/keep.txt',
      ItemKind.file,
    )..override = Retention.local;
    store.entries['Remote'] = Entry('Remote', ItemKind.directory)
      ..override = Retention.local;
    cloud.put('Documents/keep.txt', 'keep');
    cloud.put('Documents/Old/inside.txt', 'old inside');
    cloud.put('Unseen/old.txt', 'old cloud content');
    cloud.put('standalone.txt', 'old root content');
    local('.env').writeAsStringSync('ordinary hidden file');
    local('.note.kate-swp').writeAsStringSync('editor recovery');
    cloud.put('.note.kate-swp', 'old ignored remote');
    await engine.tick();
    expect(store.setting('retention'), 'local');
    expect(engine.defaultRetention, Retention.local);
    // Documents stays Local (spec #34 P7): files directly in it are kept
    // here; folders inside it would take the former Cloud choice.
    expect(store.entries['Documents']!.override, isNull);
    expect(store.entries['Remote']!.override, Retention.local);
    expect(store.entries['Unseen']!.override, Retention.cloud);
    expect(engine.retention('Documents/keep.txt'), Retention.local);
    expect(local('Documents/keep.txt').readAsStringSync(), 'keep');
    expect(store.entries['Documents/Old']!.override, Retention.cloud);
    expect(local('Documents/Old/inside.txt').existsSync(), false);
    expect(local('Unseen/old.txt').existsSync(), false);
    expect(local('standalone.txt').readAsStringSync(), 'old root content');
    expect(store.entries.containsKey('.note.kate-swp'), false);
    expect(local('.note.kate-swp').readAsStringSync(), 'editor recovery');
    expect(cloud.files['.note.kate-swp'], 'old ignored remote'.codeUnits);
    expect(engine.retention('.env'), Retention.local);
    reopen();
    local('fresh.txt').writeAsStringSync('fresh');
    cloud.put('fresh-remote.txt', 'fresh remote');
    await engine.tick();
    expect(engine.retention('fresh.txt'), Retention.local);
    expect(local('fresh.txt').readAsStringSync(), 'fresh');
    expect(local('fresh-remote.txt').readAsStringSync(), 'fresh remote');
    expect(local('Unseen/old.txt').existsSync(), false);
  });

  test('offline migration preserves bytes and journals without discovery or sync, then retries after restart', () async {
    store.setSetting('retention', 'cloud');
    local('pending.txt').writeAsStringSync('pending');
    final op = Operation('existing', 'upload', 'pending.txt');
    store.operations[op.id] = op;
    store.save();
    cloud.online = false;
    await engine.tick();
    expect(engine.message, contains('Storage upgrade pending'));
    expect(store.setting('retention'), 'cloud');
    expect(store.entries, isEmpty);
    expect(store.operations.keys, ['existing']);
    expect(local('pending.txt').readAsStringSync(), 'pending');
    expect(cloud.downloads, 0);
    expect(cloud.files, isEmpty);
    reopen();
    cloud.online = true;
    cloud.put('unknown.txt', 'cloud');
    await engine.tick();
    expect(store.setting('retention'), 'local');
    expect(engine.retention('unknown.txt'), Retention.local);
    expect(local('unknown.txt').readAsStringSync(), 'cloud');
    expect(cloud.files['pending.txt'], 'pending'.codeUnits);
  });

  test('pending incomplete listing refuses direct actions before any staging or download', () async {
    store.setSetting('retention', 'cloud');
    store.entries['tracked.txt'] = Entry('tracked.txt', ItemKind.file)
      ..etag = '"v1"';
    store.save();
    cloud.put('tracked.txt', 'remote tracked bytes');
    cloud.incompleteSnapshot = true;
    await engine.tick();
    expect(engine.message, contains('incomplete listing'));
    await expectLater(
      engine.openFile('tracked.txt'),
      throwsA(isA<CloudFailure>()),
    );
    await expectLater(
      engine.keepBoth('tracked.txt'),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => engine.setRetention('tracked.txt', Retention.local),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => engine.requestDelete('tracked.txt'),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => engine.editing.request('tracked.txt', []),
      throwsA(isA<CloudFailure>()),
    );
    expect(store.entries['tracked.txt']!.override, null);
    expect(store.operations, isEmpty);
    expect(tree.staging.listSync(), isEmpty);
    expect(cloud.downloads, 0);
    cloud.incompleteSnapshot = false;
    await engine.tick();
    expect(store.setting('retention'), 'local');
    final copy = await engine.openFile('tracked.txt');
    expect(File(copy).readAsStringSync(), 'remote tracked bytes');
  });

  test('policy transaction failure rolls back in memory and disk before restart retry', () async {
    store.setSetting('retention', 'cloud');
    store.entries['Documents'] = Entry('Documents', ItemKind.directory);
    store.save();
    cloud.put('unseen.txt', 'cloud');
    store.db.execute(
      "CREATE TRIGGER fail_migration BEFORE INSERT ON entries WHEN NEW.path='unseen.txt' BEGIN SELECT RAISE(ABORT, 'interrupted'); END",
    );
    await engine.tick();
    expect(engine.message, contains('Storage upgrade pending'));
    expect(store.setting('retention'), 'cloud');
    expect(store.entries.keys, ['Documents']);
    expect(store.entries['Documents']!.override, null);
    expect(cloud.downloads, 0);
    reopen();
    expect(store.setting('retention'), 'cloud');
    expect(store.entries['Documents']!.override, null);
    store.db.execute('DROP TRIGGER fail_migration');
    await engine.tick();
    expect(store.setting('retention'), 'local');
    expect(store.entries['unseen.txt']!.override, isNull);
    expect(cloud.downloads, 1);
  });

  test('unavailable local root and replacement during remote scan leave migration pending', () async {
    store.setSetting('retention', 'cloud');
    final original = tree.root.path;
    tree.root.renameSync('$original-moved');
    await engine.tick();
    expect(store.setting('retention'), 'cloud');
    expect(store.entries, isEmpty);
    Directory('$original-moved').renameSync(original);
    cloud.afterSnapshot = () => tree.root.renameSync('$original-moved');
    await engine.tick();
    expect(store.setting('retention'), 'cloud');
    expect(store.entries, isEmpty);
    expect(cloud.downloads, 0);
  });

  for (final pin in ['accountUid', 'accountOrigin', 'certificate', 'server']) {
    test(
      'previous $pin prevents offline migration even without usable credentials',
      () async {
        store.setSetting('retention', 'cloud');
        store.setSetting(pin, 'previous-enrollment');
        engine = SyncEngine(store, tree, const DisconnectedCloud());
        await engine.tick();
        expect(store.setting('retention'), 'cloud');
        expect(engine.message, contains('Storage upgrade pending'));
        expect(store.entries, isEmpty);
      },
    );
  }
  test('never-paired old Cloud setup migrates without a nonexistent remote namespace', () async {
    store.setSetting('retention', 'cloud');
    local('unpaired.txt').writeAsStringSync('keep local bytes');
    engine = SyncEngine(store, tree, const DisconnectedCloud());
    await engine.tick();
    expect(store.setting('retention'), 'local');
    expect(engine.retention('unpaired.txt'), Retention.local);
    expect(local('unpaired.txt').readAsStringSync(), 'keep local bytes');
    expect(engine.message, startsWith('Offline:'));
  });

  for (final phase in ['before-commit', 'after-commit']) {
    test(
      'process interruption $phase preserves atomic migration across restart',
      () async {
        final target = '${fixture.path}/crash-$phase';
        final dart = testDartExecutable;
        final crash = await Process.run(dart, [
          'run',
          'tool/root_policy_fixture.dart',
          target,
          phase,
        ]);
        expect(crash.exitCode, 86, reason: '${crash.stdout} ${crash.stderr}');
        final persisted = Manifest(Directory('$target/profile'));
        expect(
          persisted.setting('retention'),
          phase == 'before-commit' ? 'cloud' : 'local',
        );
        expect(
          persisted.entries['Old']?.override,
          phase == 'before-commit' ? null : Retention.cloud,
        );
        persisted.close();
        final resume = await Process.run(dart, [
          'run',
          'tool/root_policy_fixture.dart',
          target,
          'resume',
        ]);
        expect(resume.exitCode, 0, reason: '${resume.stdout} ${resume.stderr}');
      },
    );
  }

  test(
    'controller root creation persists Local without a retention argument',
    () async {
      final profile = Directory('${fixture.path}/new-profile');
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      try {
        await controller.initialize();
        final parent = Directory('${fixture.path}/new-parent')..createSync();
        await controller.configureRoot(parent.path);
        await controller.stop();
        final created = Manifest(profile);
        expect(created.setting('retention'), 'local');
        expect(created.setting('root'), '${parent.path}/anj-cloud');
        created.close();
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );

  test(
    'worker refuses direct root actions beyond the controller boundary',
    () async {
      store.setSetting('root', tree.root.path);
      store.setSetting('staging', tree.staging.path);
      store.setSetting('rootIdentity', tree.native.rootInfo(tree.fd).identity);
      store.setSetting('retention', 'local');
      store.close();
      final output = ReceivePort();
      final events = StreamIterator<dynamic>(output);
      final worker = await Isolate.spawn(syncWorker, {
        'output': output.sendPort,
        'nativeLibrary': testNativeLibrary,
        'profile': '${fixture.path}/profile',
        'privateKey': null,
      });
      try {
        expect(await events.moveNext(), true);
        final input = (events.current as Map)['input'] as SendPort;
        for (final action in ['retention', 'delete']) {
          input.send({'action': action, 'path': '.', 'value': 'cloud'});
          do {
            expect(
              await events.moveNext().timeout(const Duration(seconds: 5)),
              true,
            );
          } while (!(events.current as Map)['message'].toString().contains(
            'Invalid relative path',
          ));
        }
        input.send({'action': 'stop'});
        do {
          expect(
            await events.moveNext().timeout(const Duration(seconds: 5)),
            true,
          );
        } while ((events.current as Map)['event'] != 'stopped');
      } finally {
        worker.kill(priority: Isolate.immediate);
        await events.cancel();
        output.close();
        store = Manifest(Directory('${fixture.path}/profile'));
        engine = SyncEngine(store, tree, cloud);
      }
      expect(store.setting('retention'), 'local');
      expect(store.entries.containsKey('.'), false);
      expect(store.operations, isEmpty);
    },
  );
}
