import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _Cloud extends FakeCloud {
  final uploaded = <String>[];
  final downloaded = <String>[];
  final removed = <String>[];
  int folderDeletes = 0;
  @override
  Future<String> upload(String path, File file, {required String? etag}) async {
    uploaded.add(path);
    return super.upload(path, file, etag: etag);
  }

  @override
  Future<void> download(String path, File file, {required String etag}) async {
    downloaded.add(path);
    return super.download(path, file, etag: etag);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    removed.add(path);
    return super.deleteFile(path, etag: etag);
  }

  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    folderDeletes++;
    for (final child in {
      ...files.keys,
      ...directories,
    }.where((v) => v == path || v.startsWith('$path/')).toList()) {
      if (this.versions[child] != versions[child]) {
        throw const CloudFailure('incomplete version proof');
      }
      files.remove(child);
      directories.remove(child);
      this.versions.remove(child);
    }
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-sync-ignore-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'ignore', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = _Cloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) {
    final file = File('${tree.root.path}/$path');
    file.parent.createSync(recursive: true);
    return file;
  }

  Entry tracked(String path, String body) {
    final hash = sha256.convert(body.codeUnits).toString();
    final entry = Entry(path, ItemKind.file)
      ..baselineHash = hash
      ..localHash = hash
      ..expectedPresent = true
      ..etag = cloud.versions[path]
      ..status = 'current local';
    store.entries[path] = entry;
    return entry;
  }

  test(
    'exact case-sensitive names at any depth, no broad dot or suffix exclusion',
    () {
      for (final name in [
        '.a.kate.swp',
        '.two words.kate.swp',
        '.a.kate-swp',
        '.two words.kate-swp',
        '..env.kate.swp',
        '..env.kate-swp',
        '.line\nname.kate-swp',
        '.DS_Store',
        'Thumbs.db',
        'desktop.ini',
        // macOS and Office names (spec #31 M4).
        '._note.txt',
        '._.DS_Store',
        '._x',
        'Icon\r',
        '.localized',
        '.TemporaryItems',
        '.Trashes',
        '.fseventsd',
        '.Spotlight-V100',
        '.DocumentRevisions-V100',
        r'~$Report.docx',
        r'~$x',
      ]) {
        expect(isSyncExcluded(name), true, reason: name);
        expect(isSyncExcluded('Documents/deep/$name'), true);
        expect(isSyncExcluded('$name/subtree/ordinary.txt'), true);
      }
      for (final name in [
        '.kate.swp',
        '..kate.swp',
        '.kate-swp',
        '..kate-swp',
        'a.kate-swp',
        '.a.KATE-swp',
        '.a.kate-SWP',
        '.a.kate-swp.tmp',
        '.a.kate-swp~',
        '.a.kate.swp\n',
        '.a.kate-swp\n',
        'a.kate.swp',
        '.a.KATE.swp',
        '.a.kate.swp.tmp',
        '.ds_store',
        'thumbs.db',
        'Desktop.ini',
        '.env',
        '.gitignore',
        '.git/config',
        '.notes/data',
        'ordinary.tmp',
        'backup~',
        // Only the exact macOS and Office forms.
        '._',
        '_.note.txt',
        'a._note.txt',
        '.note._txt',
        'Icon',
        'icon\r',
        'Icon\r.txt',
        'Icon\r\r',
        '.localized.txt',
        'Readme.localized',
        '.trashes',
        '.Trashes2',
        '.temporaryitems',
        '.Spotlight-V100.bak',
        r'~$',
        r'$~x',
        '~Report.docx',
        r'x~$Report.docx',
        r'.~$Report.docx',
      ]) {
        expect(isSyncExcluded(name), false, reason: name);
      }
      // Spec #34 P3: the app's staging probe, at the top of the root only.
      final probe = '.anj-cloud-probe-${'0f' * 16}';
      expect(isSyncExcluded(probe), true);
      expect(isSyncExcluded('$probe/x'), true);
      for (final name in [
        'Documents/$probe',
        '.anj-cloud-probe-',
        '.anj-cloud-probe-${'0F' * 16}',
        '.anj-cloud-probe-${'0f' * 15}',
        '.anj-cloud-staging-01234567',
      ]) {
        expect(isSyncExcluded(name), false, reason: name);
      }
    },
  );

  for (final document in ['note.txt', '.env']) {
    for (final suffix in ['.kate.swp', '.kate-swp']) {
      test(
        'Kate $document $suffix creation, changes and removal never transfer or enter any library tab',
        () async {
          final swapPath = 'Documents/deep/.$document$suffix';
          final notePath = 'Documents/deep/$document';
          final swap = local(swapPath)
            ..writeAsStringSync('editor recovery one');
          final note = local(notePath)..writeAsStringSync('saved one');
          Future<void> expectUntracked() async {
            expect(store.entries.containsKey(swapPath), false);
            final projected = [
              for (final entry in store.entries.values)
                Map<String, dynamic>.from(await projectEntry(engine, entry)),
            ];
            for (final tab in LibraryTab.values) {
              expect(
                libraryRows(
                  projected,
                  tab,
                  {},
                ).any((row) => row.path == swapPath),
                false,
              );
            }
          }

          await engine.tick();
          await expectUntracked();
          expect(cloud.files.containsKey(swapPath), false);
          swap.writeAsStringSync('editor recovery two');
          note.writeAsStringSync('saved two');
          await engine.tick();
          await expectUntracked();
          expect(swap.readAsStringSync(), 'editor recovery two');
          // Simulate this owned fixture editor removing its recovery file on close.
          swap.deleteSync();
          await engine.tick();
          await expectUntracked();
          expect(String.fromCharCodes(cloud.files[notePath]!), 'saved two');
          expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
          expect(cloud.removed, isEmpty);
          expect(store.entries.keys.where(isSyncExcluded), isEmpty);
        },
      );
    }
  }

  test('OS names and excluded directory subtrees stay local; ordinary dots round-trip', () async {
    for (final path in [
      '.DS_Store',
      'Documents/Thumbs.db',
      'Videos/desktop.ini',
      '.blocked.kate.swp/nested/file.txt',
    ]) {
      local(path).writeAsStringSync('local metadata');
    }
    for (final path in [
      '.env',
      '.gitignore',
      '.git/config',
      '.git/objects/object',
      'Documents/normal.tmp',
      'Documents/backup~',
    ]) {
      local(path).writeAsStringSync('wanted $path');
    }
    cloud.put('Documents/.remote.kate.swp', 'remote recovery');
    cloud.put('Documents/.remote-dot', 'wanted remote dot');
    await engine.tick();
    expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
    expect(cloud.directories.where(isSyncExcluded), isEmpty);
    expect(cloud.downloaded.where(isSyncExcluded), isEmpty);
    expect(local('Documents/.remote.kate.swp').existsSync(), false);
    expect(
      local('Documents/.remote-dot').readAsStringSync(),
      'wanted remote dot',
    );
    expect(
      String.fromCharCodes(cloud.files['.git/config']!),
      'wanted .git/config',
    );
    expect(String.fromCharCodes(cloud.files['.env']!), 'wanted .env');
    expect(store.entries.keys.where(isSyncExcluded), isEmpty);
  });

  test('macOS and Office names stay local in both directions; their documents sync', () async {
    for (final path in [
      'Documents/._Report.docx',
      'Documents/Icon\r',
      'Documents/.localized',
      r'Documents/~$Report.docx',
      '.Trashes/501/deleted.txt',
      '.fseventsd/0000000000000001',
      '.Spotlight-V100/Store-V2/store.db',
      '.DocumentRevisions-V100/db-V1/db.sqlite',
      'Documents/.TemporaryItems/folders.501/item.rtf',
    ]) {
      local(path).writeAsStringSync('macOS metadata $path');
    }
    local('Documents/Report.docx').writeAsStringSync('the document');
    local('Documents/Icon').writeAsStringSync('a file named Icon');
    cloud.put('Documents/._remote.txt', 'remote AppleDouble');
    cloud.put(r'Documents/~$remote.docx', 'remote Office owner file');
    cloud.put('Documents/remote.txt', 'remote document');
    await engine.tick();
    await engine.tick();
    expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
    expect(cloud.directories.where(isSyncExcluded), isEmpty);
    expect(cloud.downloaded.where(isSyncExcluded), isEmpty);
    expect(store.entries.keys.where(isSyncExcluded), isEmpty);
    expect(cloud.removed, isEmpty);
    expect(
      String.fromCharCodes(cloud.files['Documents/Report.docx']!),
      'the document',
    );
    expect(
      String.fromCharCodes(cloud.files['Documents/Icon']!),
      'a file named Icon',
    );
    expect(local('Documents/remote.txt').readAsStringSync(), 'remote document');
    expect(local('Documents/._remote.txt').existsSync(), false);
    expect(local(r'Documents/~$remote.docx').existsSync(), false);
    expect(
      local('Documents/._Report.docx').readAsStringSync(),
      'macOS metadata Documents/._Report.docx',
    );
    // The remote copies of excluded names stay where they are.
    expect(cloud.files.containsKey('Documents/._remote.txt'), true);
    expect(cloud.files.containsKey(r'Documents/~$remote.docx'), true);
  });

  for (final path in ['Documents/._old.txt', r'Documents/~$Old.docx']) {
    test('tracked $path untracks without local or remote deletion', () async {
      local(path).writeAsStringSync('keep local bytes');
      cloud.put(path, 'keep remote bytes');
      tracked(path, 'older baseline');
      store.save();
      await engine.tick();
      expect(store.entries.containsKey(path), false);
      expect(local(path).readAsStringSync(), 'keep local bytes');
      expect(String.fromCharCodes(cloud.files[path]!), 'keep remote bytes');
      local(path).deleteSync();
      await engine.tick();
      expect(cloud.removed, isEmpty);
      expect(cloud.files.containsKey(path), true);
      expect(
        store.operations.values.where(
          (o) => o.kind == 'excluded-entry' && o.path == path,
        ),
        hasLength(1),
      );
    });
  }

  test('existing tracked exclusions untrack without local or remote deletion across restart', () async {
    const path = 'Documents/.old.txt.kate.swp';
    local(path).writeAsStringSync('keep local editor bytes');
    cloud.put(path, 'keep remote bytes');
    tracked(path, 'older baseline');
    store.save();
    await engine.tick();
    expect(store.entries.containsKey(path), false);
    expect(local(path).readAsStringSync(), 'keep local editor bytes');
    expect(String.fromCharCodes(cloud.files[path]!), 'keep remote bytes');
    expect(
      store.operations.values.where(
        (o) => o.kind == 'excluded-entry' && o.path == path,
      ),
      hasLength(1),
    );
    final root = tree.root.path;
    final stage = tree.staging.path;
    engine.close();
    tree = RootTree(Directory(root), Directory(stage), NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    engine = SyncEngine(store, tree, cloud);
    local(path).deleteSync();
    await engine.tick();
    expect(cloud.removed, isEmpty);
    expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
    expect(
      store.operations.values.where(
        (o) => o.kind == 'excluded-entry' && o.path == path,
      ),
      hasLength(1),
    );
  });

  test('new hyphen exclusion migrates tracked, queued and uncertain state without deleting any bytes', () async {
    const path = 'Documents/deep/..env.kate-swp';
    const remoteOnly = 'Documents/deep/.remote.kate-swp';
    local(path).writeAsStringSync('live Kate local recovery');
    local('Documents/deep/.env').writeAsStringSync('wanted environment file');
    cloud.put(path, 'previous cloud recovery');
    cloud.put(remoteOnly, 'remote-only recovery');
    final remoteVersion = cloud.versions[path];
    tracked(path, 'older tracked baseline');
    final privateCopies = <File>[];
    final ownership = <String, String>{};
    for (final id in ['queued-upload', 'uncertain-upload']) {
      final snapshot = engine.artifacts.reserve(path, 'upload')
        ..writeAsStringSync('private $id snapshot');
      final hash = sha256.convert(snapshot.readAsBytesSync()).toString();
      engine.artifacts.complete(snapshot, hash: hash);
      privateCopies.add(snapshot);
      final record = engine.artifacts.record(snapshot)!;
      ownership[record.id] = record.data['identity'] as String;
      store.operations[id] =
          Operation(
              id,
              'upload',
              path,
              staged: snapshot.path,
              hash: hash,
              expectedEtag: '"older-version"',
            )
            ..data['dispatchState'] = id.startsWith('queued')
                ? 'not-started'
                : 'started';
    }
    for (final id in ['queued-delete', 'uncertain-delete']) {
      store.operations[id] =
          Operation(id, 'delete', path, expectedEtag: remoteVersion)
            ..data['dispatchState'] = id.startsWith('queued')
                ? 'not-started'
                : 'started';
    }
    store.save();
    Future<void> expectPreserved() async {
      expect(local(path).readAsStringSync(), 'live Kate local recovery');
      expect(
        String.fromCharCodes(cloud.files[path]!),
        'previous cloud recovery',
      );
      expect(cloud.versions[path], remoteVersion);
      expect(local(remoteOnly).existsSync(), false);
      for (var i = 0; i < privateCopies.length; i++) {
        expect(
          privateCopies[i].readAsStringSync(),
          'private ${i == 0 ? 'queued-upload' : 'uncertain-upload'} snapshot',
        );
      }
      for (final record in ownership.entries) {
        expect(store.operations[record.key]!.kind, 'artifact');
        expect(store.operations[record.key]!.data['identity'], record.value);
        expect(store.operations[record.key]!.data['syncExcluded'], true);
      }
      expect(
        store.operations.values.where(
          (operation) =>
              operation.kind == 'excluded-entry' && operation.path == path,
        ),
        hasLength(1),
      );
      for (final id in [
        'queued-upload',
        'queued-delete',
        'uncertain-upload',
        'uncertain-delete',
      ]) {
        final archived = store.operations[id]!;
        expect(archived.kind, 'excluded-operation');
        expect(
          archived.phase,
          id.startsWith('queued')
              ? 'cancelled-before-dispatch'
              : 'retained-history',
        );
        expect((archived.data['original'] as Map)['id'], id);
      }
      final projected = [
        for (final entry in store.entries.values)
          Map<String, dynamic>.from(await projectEntry(engine, entry)),
      ];
      for (final tab in LibraryTab.values) {
        expect(
          libraryRows(
            projected,
            tab,
            {},
          ).any((row) => isSyncExcluded(row.path)),
          false,
        );
      }
      expect(
        libraryRows(
          projected,
          LibraryTab.home,
          {},
        ).any((row) => row.path == 'Documents/deep/.env'),
        true,
      );
      expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
      expect(cloud.removed, isEmpty);
      expect(cloud.folderDeletes, 0);
    }

    await engine.tick();
    await expectPreserved();
    final reads = cloud.downloaded.length; // Only historical uncertain-upload proof may read excluded bytes.
    expect(cloud.downloaded.where((name) => name == path), hasLength(1));
    expect(cloud.downloaded, isNot(contains(remoteOnly)));
    final root = tree.root.path;
    final stage = tree.staging.path;
    engine.close();
    tree = RootTree(Directory(root), Directory(stage), NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    engine = SyncEngine(store, tree, cloud);
    await engine.tick();
    await expectPreserved();
    expect(cloud.downloaded.length, reads);
    expect(
      String.fromCharCodes(cloud.files['Documents/deep/.env']!),
      'wanted environment file',
    );
  });

  test(
    'known undispatched intents cancel atomically, private source bytes remain',
    () async {
      const path = 'Documents/desktop.ini';
      cloud.put(path, 'existing remote');
      tracked(path, 'old bytes');
      local(path).writeAsStringSync('local OS bytes');
      final staged = engine.artifacts.reserve(path, 'upload')
        ..writeAsStringSync('private upload bytes');
      engine.artifacts.complete(
        staged,
        hash: sha256.convert('private upload bytes'.codeUnits).toString(),
      );
      final upload = Operation(
        'pending-upload',
        'upload',
        path,
        staged: staged.path,
        hash: 'snapshot',
      )..data['dispatchState'] = 'not-started';
      final delete = Operation(
        'pending-delete',
        'delete',
        path,
        expectedEtag: cloud.versions[path],
      )..data['dispatchState'] = 'not-started';
      store.operations[upload.id] = upload;
      store.operations[delete.id] = delete;
      store.save();
      await engine.tick();
      expect(store.operations[upload.id]!.phase, 'cancelled-before-dispatch');
      expect(store.operations[delete.id]!.phase, 'cancelled-before-dispatch');
      expect(staged.readAsStringSync(), 'private upload bytes');
      expect(local(path).readAsStringSync(), 'local OS bytes');
      expect(String.fromCharCodes(cloud.files[path]!), 'existing remote');
      expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
      expect(cloud.removed, isEmpty);
    },
  );

  test('legacy prepared uncertain upload observes exact remote version without replay', () async {
    const path = 'Documents/.legacy.kate.swp';
    cloud.put(path, 'accepted before crash');
    local(path).writeAsStringSync('still local');
    tracked(path, 'old baseline');
    final staged = engine.artifacts.reserve(path, 'upload')
      ..writeAsStringSync('accepted before crash');
    final hash = sha256.convert('accepted before crash'.codeUnits).toString();
    engine.artifacts.complete(staged, hash: hash);
    final upload = Operation(
      'legacy-uncertain',
      'upload',
      path,
      staged: staged.path,
      hash: hash,
      expectedEtag: '"old-etag"',
    );
    store.operations[upload.id] = upload;
    store.save();
    await engine.tick();
    final archive = store.operations[upload.id]!;
    expect(archive.kind, 'excluded-operation');
    expect(archive.phase, 'retained-history');
    expect(archive.data['matchesRequestedUpload'], true);
    expect((archive.data['original'] as Map)['phase'], 'prepared');
    expect(staged.readAsStringSync(), 'accepted before crash');
    expect(cloud.uploaded.where(isSyncExcluded), isEmpty);
    expect(cloud.removed, isEmpty);
    final downloads = cloud.downloaded.length;
    await engine.tick();
    expect(cloud.downloaded.length, downloads);
    expect(store.entries.keys.where(isSyncExcluded), isEmpty);
  });

  test(
    'legacy prepared delete is never replayed and keeps inconclusive history',
    () async {
      const path = 'Documents/Thumbs.db';
      cloud.put(path, 'remote OS bytes');
      tracked(path, 'old baseline');
      store.operations['old-delete'] = Operation(
        'old-delete',
        'delete',
        path,
        expectedEtag: cloud.versions[path],
      );
      store.save();
      await engine.tick();
      expect(cloud.removed, isEmpty);
      expect(cloud.files.containsKey(path), true);
      expect(store.operations['old-delete']!.phase, 'retained-history');
      expect(
        store.operations['old-delete']!.data['observation'],
        contains('unknown'),
      );
    },
  );

  for (final suffix in ['.kate.swp', '.kate-swp']) {
    test(
      'new unobserved $suffix descendants block parent deletion using unfiltered tree',
      () async {
        cloud.foldersQualified = true;
        tree.ensureDirectory('Documents/Mixed');
        local('Documents/Mixed/wanted.txt').writeAsStringSync('wanted');
        await engine.tick();
        await engine.tick();
        cloud.put('Documents/Mixed/..env$suffix', 'previous remote recovery');
        engine.requestDelete('Documents/Mixed');
        await engine.tick();
        expect(cloud.folderDeletes, 0);
        expect(cloud.removed, isEmpty);
        expect(cloud.files.containsKey('Documents/Mixed/..env$suffix'), true);
        expect(
          store.entries['Documents/Mixed']!.conflict,
          contains('excluded cloud descendants'),
        );
        expect(cloud.downloaded.where(isSyncExcluded), isEmpty);
      },
    );
  }

  test('remote folder removal retains local ignored bytes without resurrection or recursive cleanup', () async {
    tree.ensureDirectory('Documents/Mixed');
    local('Documents/Mixed/wanted.txt').writeAsStringSync('wanted');
    await engine.tick();
    await engine.tick();
    final swap = local('Documents/Mixed/.wanted.txt.kate.swp')
      ..writeAsStringSync('live editor recovery');
    cloud.remove('Documents/Mixed/wanted.txt');
    cloud.directories.remove('Documents/Mixed');
    cloud.versions.remove('Documents/Mixed');
    await engine.tick();
    expect(swap.readAsStringSync(), 'live editor recovery');
    expect(local('Documents/Mixed/wanted.txt').existsSync(), false);
    expect(
      store.entries['Documents/Mixed']!.status,
      contains('excluded local files retained'),
    );
    await engine.tick();
    await engine.tick();
    expect(cloud.directories.contains('Documents/Mixed'), false);
    expect(
      cloud.files.keys.where((v) => v.startsWith('Documents/Mixed/')),
      isEmpty,
    );
    expect(swap.readAsStringSync(), 'live editor recovery');
  });
  test('excluded private ownership does not block unrelated guarded Cloud reclamation', () async {
    const ignored = 'Documents/.old.kate.swp';
    final saved = engine.artifacts.reserve(ignored, 'upload')
      ..writeAsStringSync('old private recovery');
    engine.artifacts.complete(
      saved,
      hash: sha256.convert(saved.readAsBytesSync()).toString(),
    );
    // Documents itself is never Cloud-only (spec #34 P7).
    tree.ensureDirectory('Documents/Cloud');
    final wanted = local('Documents/Cloud/reclaim.txt')
      ..writeAsStringSync('synchronized normal file');
    await engine.tick();
    engine.setRetention('Documents/Cloud', Retention.cloud);
    await engine.tick();
    expect(wanted.existsSync(), false);
    expect(saved.readAsStringSync(), 'old private recovery');
    expect(engine.artifacts.hasLegacyOrUncertain, false);
    expect(engine.artifacts.record(saved)!.data['syncExcluded'], true);
    expect(
      String.fromCharCodes(cloud.files['Documents/Cloud/reclaim.txt']!),
      'synchronized normal file',
    );
  });

  for (final phase in ['before-commit', 'after-commit']) {
    test('real restart exclusion migration is atomic at $phase', () async {
      final target = '${fixture.path}/crash-$phase';
      final dart = testDartExecutable;
      final crashed = await Process.run(dart, [
        'run',
        'tool/exclusion_fixture.dart',
        target,
        phase,
      ]);
      expect(
        crashed.exitCode,
        86,
        reason: '${crashed.stdout} ${crashed.stderr}',
      );
      final resumed = await Process.run(dart, [
        'run',
        'tool/exclusion_fixture.dart',
        target,
        'resume',
      ]);
      expect(
        resumed.exitCode,
        0,
        reason: '${resumed.stdout} ${resumed.stderr}',
      );
      final result =
          jsonDecode(File('$target/result.json').readAsStringSync()) as Map;
      expect(result['active_ignored'], 0);
      expect(result['operation_kind'], 'excluded-operation');
      expect(result['original_phase'], 'prepared');
      expect(result['local'], 'local editor data');
      expect(result['remote'], 'remote data');
      expect(result['private'], 'private uncertain snapshot');
    });
  }
  test('known excluded descendants join frozen full subtree proof for legitimate directory deletion', () async {
    cloud.foldersQualified = true;
    tree.ensureDirectory('Documents/Known');
    local('Documents/Known/wanted.txt').writeAsStringSync('wanted');
    await engine.tick();
    await engine.tick();
    final localNoise = local('Documents/Known/.wanted.kate.swp')
      ..writeAsStringSync('local editor recovery');
    cloud.put('Documents/Known/.old.kate.swp', 'historical remote noise');
    await engine.tick();
    engine.requestDelete('Documents/Known');
    final intent = engine.operation('Documents/Known', 'delete')!;
    expect(
      (intent.data['excludedSubtreeVersions'] as Map).keys,
      contains('Documents/Known/.old.kate.swp'),
    );
    await engine.tick();
    expect(cloud.folderDeletes, 1);
    expect(
      cloud.files.keys.where((v) => v.startsWith('Documents/Known/')),
      isEmpty,
    );
    expect(cloud.directories.contains('Documents/Known'), false);
    expect(localNoise.readAsStringSync(), 'local editor recovery');
    await engine.tick();
    expect(cloud.directories.contains('Documents/Known'), false);
  });

  test(
    'queued directory delete never refreshes changed excluded baselines',
    () async {
      cloud.foldersQualified = true;
      tree.ensureDirectory('Documents/Changed');
      local('Documents/Changed/wanted.txt').writeAsStringSync('wanted');
      await engine.tick();
      const ignored = 'Documents/Changed/desktop.ini';
      cloud.put(ignored, 'old metadata');
      await engine.tick();
      engine.requestDelete('Documents/Changed');
      final intent = engine.operation('Documents/Changed', 'delete')!;
      final frozen = (intent.data['excludedSubtreeVersions'] as Map)[ignored];
      cloud.put(ignored, 'new metadata');
      await engine.tick();
      await engine.tick();
      expect(cloud.folderDeletes, 0);
      expect(String.fromCharCodes(cloud.files[ignored]!), 'new metadata');
      expect((intent.data['excludedSubtreeVersions'] as Map)[ignored], frozen);
      expect(
        store.entries['Documents/Changed']!.conflict,
        contains('excluded cloud descendants'),
      );
    },
  );

  for (final suffix in ['.kate.swp', '.kate-swp']) {
    test(
      'legacy parent delete without $suffix baseline stays pending rather than guessing',
      () async {
        cloud.foldersQualified = true;
        tree.ensureDirectory('Documents/Legacy');
        local('Documents/Legacy/wanted.txt').writeAsStringSync('wanted');
        await engine.tick();
        await engine.tick();
        cloud.put('Documents/Legacy/..env$suffix', 'retain');
        store.operations['legacy-folder-delete'] = Operation(
          'legacy-folder-delete',
          'delete',
          'Documents/Legacy',
          expectedEtag: cloud.versions['Documents/Legacy'],
        );
        store.save();
        await engine.tick();
        expect(cloud.folderDeletes, 0);
        expect(
          store.entries['Documents/Legacy']!.status,
          contains('lack a known intent baseline'),
        );
        expect(cloud.files.containsKey('Documents/Legacy/..env$suffix'), true);
      },
    );
  }
}
