import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/library_move.dart';
import 'package:anj_cloud/core/sync/documents_ops.dart';
import 'package:anj_cloud/core/sync/open_documents.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Cloud extends FakeCloud {
  @override
  Future<List<RemoteItem>> snapshot() async => [
    for (final item in await super.snapshot())
      if (item.kind == ItemKind.directory)
        RemoteItem(
          item.path,
          item.kind,
          item.etag,
          fileId: 5000 + directories.toList().indexOf(item.path),
        )
      else
        item,
  ];
}

void main() {
  late Directory temp;
  late SyncEngine engine;
  late _Cloud cloud;
  late LibraryMove moves;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('library-move-');
    final tree = RootTree.setup(
      (Directory('${temp.path}/files')..createSync()).path,
      'move',
      NativeRootFs(),
    );
    cloud = _Cloud();
    await cloud.mkdir('Videos');
    await cloud.mkdir('Documents');
    cloud.put('Videos/movie.mp4', 'same bytes');
    engine = SyncEngine(
      Manifest(Directory('${temp.path}/profile')),
      tree,
      cloud,
    );
    moves = LibraryMove(
      engine,
      OpenDocuments(),
      (file, dest, parentId, job) =>
          cloud.move(file.path, dest, etag: file.etag),
      relocate: DocumentsOps(engine).relocate,
    );
  });
  tearDown(() {
    engine.close();
    temp.deleteSync(recursive: true);
  });

  Future<Map> pick(List<String> paths) async {
    final plan = await moves.handle('moveChoices', {
      'files': [
        for (final path in paths)
          {
            'path': path,
            'fileId': cloud.fileIds[path],
            'etag': cloud.versions[path],
            'selectionVersion': engine.selectionVersion(
              engine.manifest.entries[path]!,
            ),
          },
      ],
    });
    return {
      ...plan,
      'folder': 'Documents',
      'parentId': (plan['folders'] as Map)['Documents'],
    };
  }

  test('move one or several synced files, report collisions and retain both copies', () async {
    cloud.put('Videos/two.mp4', 'new');
    cloud.put('Documents/two.mp4', 'existing');
    await engine.tick();
    await engine.tick();
    final plan = await pick(['Videos/movie.mp4', 'Videos/two.mp4']);
    final uploads = cloud.uploadAttempts;
    final result = await moves.handle('moveFiles', plan);
    expect(result['results'], [
      'Moved Videos/movie.mp4 to Documents.',
      'Videos/two.mp4: The destination already contains this name.',
    ]);
    await engine.tick();
    expect(cloud.uploadAttempts, uploads);
    expect(cloud.files['Documents/movie.mp4'], 'same bytes'.codeUnits);
    expect(cloud.files['Documents/two.mp4'], 'existing'.codeUnits);
    expect(cloud.files['Videos/two.mp4'], 'new'.codeUnits);
    expect(cloud.files['Videos/movie.mp4'], isNull);
  });

  test(
    'current folder and changed local bytes leave both copies in place',
    () async {
      await engine.tick();
      await engine.tick();
      final plan = await pick(['Videos/movie.mp4']);
      final same = await moves.handle('moveFiles', {
        ...plan,
        'folder': 'Videos',
        'parentId': (plan['folders'] as Map)['Videos'],
      });
      expect((same['results'] as List).single, contains('already here'));
      final local = File('${engine.tree.root.path}/Videos/movie.mp4');
      local.writeAsStringSync('unsynced bytes');
      final result = await moves.handle('moveFiles', plan);
      expect((result['results'] as List).single, contains('Local changes'));
      expect(cloud.moves, isEmpty);
      expect(local.readAsStringSync(), 'unsynced bytes');
      expect(cloud.files['Videos/movie.mp4'], 'same bytes'.codeUnits);
    },
  );

  test(
    'an unlisted download keeps its identity across a retry and account switch',
    () async {
      final plan = await moves.handle('moveChoices', {
        'files': [],
        'job': 'download',
        'fileId': cloud.fileIds['Videos/movie.mp4'],
      });
      final command = {
        ...plan,
        'folder': 'Documents',
        'parentId': (plan['folders'] as Map)['Documents'],
      };
      expect(engine.manifest.entries, isEmpty);
      await moves.handle('moveFiles', command);
      cloud.put('Videos/movie.mp4', 'unrelated file');
      final retry = await moves.handle('moveFiles', command);
      expect((retry['results'] as List).single, contains('File changed'));
      engine.manifest.setSetting('accountUid', 'another account');
      await expectLater(
        moves.handle('moveFiles', command),
        throwsA(isA<CloudFailure>()),
      );
      expect(cloud.files['Documents/movie.mp4'], 'same bytes'.codeUnits);
      expect(cloud.files['Videos/movie.mp4'], 'unrelated file'.codeUnits);
    },
  );

  test(
    'a never-uploaded local file moves exclusively and syncs at its new name',
    () async {
      await engine.tick();
      cloud.uploadLimit = 2;
      const path = 'Videos/local.txt';
      File('${engine.tree.root.path}/$path').writeAsStringSync('pending data');
      await engine.tick();
      expect(cloud.files[path], isNull);
      final plan = await pick([path]);
      final result = await moves.handle('moveFiles', plan);
      expect((result['results'] as List).single, contains('on this device'));
      expect(
        File('${engine.tree.root.path}/Documents/local.txt').readAsStringSync(),
        'pending data',
      );
      cloud.uploadLimit = null;
      await engine.tick();
      expect(cloud.files['Documents/local.txt'], 'pending data'.codeUnits);
      expect(cloud.files[path], isNull);
    },
  );

  test('replacement at the selected source stays intact', () async {
    await engine.tick();
    final plan = await pick(['Videos/movie.mp4']);
    cloud.remove('Videos/movie.mp4');
    cloud.put('Videos/movie.mp4', 'replacement');
    await moves.handle('moveFiles', plan);
    expect(cloud.moves, isEmpty);
    expect(cloud.files['Videos/movie.mp4'], 'replacement'.codeUnits);
  });
}
