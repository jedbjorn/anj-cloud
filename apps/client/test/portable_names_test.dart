import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Refuses chosen names the way the gateway does (decision #120).
class _NameRefusingCloud extends FakeCloud {
  final Set<String> refused = {};
  final Map<String, int> attemptsBy = {};
  final List<String> created = [];

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    attemptsBy[path] = (attemptsBy[path] ?? 0) + 1;
    if (refused.contains(path)) {
      throw const NameNotPortable(NameProblem.clash);
    }
    created.add(path);
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> mkdir(String path) async {
    attemptsBy[path] = (attemptsBy[path] ?? 0) + 1;
    if (refused.contains(path)) {
      throw const NameNotPortable(NameProblem.clash);
    }
    created.add(path);
    return super.mkdir(path);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _NameRefusingCloud cloud;
  late SyncEngine engine;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-portable-names-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'names', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _NameRefusingCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  void write(String path, String text) =>
      local(path).writeAsStringSync(text, flush: true);
  Entry entry(String path) => store.entries[path]!;
  Future<Map<String, dynamic>> projected(String path) async =>
      Map<String, dynamic>.from(await projectEntry(engine, entry(path)));
  SyncStatus overall() => deriveStatus(
    paused: false,
    offline: false,
    unpaired: false,
    message: engine.message,
    entries: store.entries.values,
    operations: store.operations.values,
  );

  test('a blocked local name stays local-only with the row', () async {
    for (final name in ['CON', 'nul.txt', 'report.', 'a:b.txt', 'x|y']) {
      write('Documents/$name', name);
    }
    await engine.tick();
    await engine.tick();
    for (final name in ['CON', 'nul.txt', 'report.', 'a:b.txt', 'x|y']) {
      final path = 'Documents/$name';
      expect(cloud.attemptsBy[path], isNull, reason: path);
      expect(cloud.files.containsKey(path), isFalse);
      expect(entry(path).status, nameNotAllowedStatus);
      expect(local(path).readAsStringSync(), name, reason: 'kept as is');
      final row = await projected(path);
      expect(row['nameRefused'], isTrue);
      expect(row['presentationErrors'], [nameNotAllowedStatus]);
      expect(libraryStatus(row), nameNotAllowedStatus);
      expect(rowBadge(row), RowBadge.needsAttention);
      expect(hasQueuedWork(row), isTrue);
    }
    expect(overall(), SyncStatus.attention);
  });

  test('ordinary names and dotfiles upload unchanged', () async {
    final names = [
      'report.txt',
      '.bashrc',
      '.env',
      '.config',
      'CONSOLE.log',
      'COM10',
      ' leading',
      '雪 #1 100%.txt',
    ];
    for (final name in names) {
      write('Documents/$name', name);
    }
    await engine.tick();
    for (final name in names) {
      final path = 'Documents/$name';
      expect(cloud.files[path], utf8.encode(name), reason: path);
      expect(entry(path).status, 'current local');
      expect((await projected(path))['nameRefused'], isFalse);
    }
    expect(overall(), isNot(SyncStatus.attention));
  });

  test('a case or normalization clash with a cloud sibling is held, and '
      'lifts when the sibling goes', () async {
    cloud.put('Documents/Notes.txt', 'cloud');
    cloud.put('Documents/café.txt', 'nfc');
    await engine.tick();
    write('Documents/notes.txt', 'local');
    write('Documents/café.txt', 'nfd');
    await engine.tick();
    await engine.tick();
    if (foldsCase(tree.root) && foldsNormalization(tree.root)) {
      // APFS: each pair of spellings is one item, so the writes edit the
      // downloaded files; there is no sibling to hold or to lift.
      expect(cloud.attemptsBy['Documents/notes.txt'], isNull);
      expect(cloud.attemptsBy['Documents/cafe\u0301.txt'], isNull);
      expect(cloud.files['Documents/Notes.txt'], 'local'.codeUnits);
      expect(cloud.files['Documents/caf\u00e9.txt'], 'nfd'.codeUnits);
      expect(entry('Documents/Notes.txt').status, 'current local');
      expect(entry('Documents/caf\u00e9.txt').status, 'current local');
      expect(store.entries.containsKey('Documents/notes.txt'), isFalse);
      return;
    }
    expect(cloud.attemptsBy['Documents/notes.txt'], isNull);
    expect(cloud.attemptsBy['Documents/café.txt'], isNull);
    expect(entry('Documents/notes.txt').status, nameNotAllowedStatus);
    expect(entry('Documents/café.txt').status, nameNotAllowedStatus);
    // Linux holds both names: the cloud file is here too, untouched.
    expect(local('Documents/Notes.txt').readAsStringSync(), 'cloud');
    expect(local('Documents/notes.txt').readAsStringSync(), 'local');
    cloud.remove('Documents/Notes.txt');
    await engine.tick();
    await engine.tick();
    expect(cloud.files['Documents/notes.txt'], 'local'.codeUnits);
    expect(entry('Documents/notes.txt').status, 'current local');
  });

  test(
    'two new local names that clash: the second waits for a rename',
    () async {
      write('Documents/Photo.jpg', 'one');
      write('Documents/photo.jpg', 'two');
      await engine.tick();
      await engine.tick();
      if (foldsCase(tree.root)) {
        // APFS: one item, Photo.jpg, holding the second write.
        expect(cloud.created, contains('Documents/Photo.jpg'));
        expect(cloud.created, isNot(contains('Documents/photo.jpg')));
        expect(cloud.files['Documents/Photo.jpg'], 'two'.codeUnits);
        expect(entry('Documents/Photo.jpg').status, 'current local');
        expect(store.entries.containsKey('Documents/photo.jpg'), isFalse);
        return;
      }
      final uploaded = cloud.created
          .where((path) => path.toLowerCase() == 'documents/photo.jpg')
          .toList();
      expect(uploaded, hasLength(1));
      final other = uploaded.single == 'Documents/Photo.jpg'
          ? 'Documents/photo.jpg'
          : 'Documents/Photo.jpg';
      expect(entry(other).status, nameNotAllowedStatus);
      expect(local(other).existsSync(), isTrue);
    },
  );

  test(
    'a gateway refusal holds the file until it changes or a retry',
    () async {
      cloud.refused.add('Documents/plain.txt');
      write('Documents/plain.txt', 'v1');
      await engine.tick();
      await engine.tick();
      await engine.tick();
      expect(cloud.attemptsBy['Documents/plain.txt'], 1);
      expect(entry('Documents/plain.txt').status, nameNotAllowedStatus);
      expect((await projected('Documents/plain.txt'))['nameRefused'], isTrue);
      cloud.refused.clear();
      engine.uploads.retryAll();
      await engine.tick();
      expect(cloud.files['Documents/plain.txt'], 'v1'.codeUnits);
      expect(entry('Documents/plain.txt').status, 'current local');
    },
  );

  test('a blocked folder keeps its contents local and pending', () async {
    Directory('${tree.root.path}/Documents/AUX').createSync();
    write('Documents/AUX/inside.txt', 'inside');
    Directory('${tree.root.path}/Documents/AUX/deeper').createSync();
    await engine.tick();
    await engine.tick();
    expect(cloud.directories, isNot(contains('Documents/AUX')));
    expect(cloud.attemptsBy.keys.where((k) => k.contains('AUX')), isEmpty);
    expect(entry('Documents/AUX').status, nameNotAllowedStatus);
    expect(entry('Documents/AUX/inside.txt').status, nameFolderPendingStatus);
    expect(entry('Documents/AUX/deeper').status, nameFolderPendingStatus);
    expect((await projected('Documents/AUX'))['nameRefused'], isTrue);
    final child = await projected('Documents/AUX/inside.txt');
    expect(child['nameRefused'], isFalse);
    expect(hasProblem(child), isTrue);
  });

  test(
    'Rename renames in place; the new name syncs and the old row ends',
    () async {
      write('Documents/CON.txt', 'bytes');
      Directory('${tree.root.path}/Documents/PRN').createSync();
      write('Documents/PRN/child.txt', 'child');
      await engine.tick();
      expect(entry('Documents/CON.txt').status, nameNotAllowedStatus);
      expect(
        await engine.renameLocal('Documents/CON.txt', 'console.txt'),
        'Documents/console.txt',
      );
      expect(
        await engine.renameLocal('Documents/PRN', 'Printouts'),
        'Documents/Printouts',
      );
      await engine.tick();
      await engine.tick();
      expect(local('Documents/CON.txt').existsSync(), isFalse);
      expect(local('Documents/console.txt').readAsStringSync(), 'bytes');
      expect(cloud.files['Documents/console.txt'], 'bytes'.codeUnits);
      expect(cloud.directories, contains('Documents/Printouts'));
      expect(cloud.files['Documents/Printouts/child.txt'], 'child'.codeUnits);
      expect(cloud.files.keys.where((k) => k.contains('CON.txt')), isEmpty);
      for (final old in [
        'Documents/CON.txt',
        'Documents/PRN',
        'Documents/PRN/child.txt',
      ]) {
        final row = await projected(old);
        expect(visibleInLibrary(row), isFalse, reason: old);
      }
      expect(overall(), isNot(SyncStatus.attention));
    },
  );

  test(
    'Rename refuses blocked, clashing and taken names, and other items',
    () async {
      write('Documents/nul', 'x');
      write('Documents/taken.txt', 'y');
      write('Documents/Other.md', 'z');
      await engine.tick();
      Future<void> refuses(String path, String name, Matcher message) =>
          expectLater(
            engine.renameLocal(path, name),
            throwsA(
              isA<FileSystemException>().having(
                (e) => e.message,
                'message',
                message,
              ),
            ),
          );
      await refuses('Documents/nul', 'aux.txt', contains('Windows reserves'));
      await refuses('Documents/nul', 'nul.', contains('Windows reserves'));
      await refuses('Documents/nul', 'x?', contains('cannot contain'));
      await refuses('Documents/nul', 'taken.txt', contains('already uses'));
      await refuses('Documents/nul', 'TAKEN.TXT', contains('upper/lower case'));
      await refuses('Documents/nul', 'a/b', contains('path separators'));
      await refuses('Documents/nul', '.DS_Store', contains('excluded'));
      await refuses(
        'Documents/taken.txt',
        'renamed.txt',
        contains('Only an item'),
      );
      expect(local('Documents/nul').readAsStringSync(), 'x');
    },
  );

  test(
    'a cloud file with a blocked name is held and edited on Linux',
    () async {
      cloud.put('Documents/AUX.txt', 'cloud');
      cloud.put('Documents/A.txt', 'upper');
      cloud.put('Documents/a.txt', 'lower');
      await engine.tick();
      expect(local('Documents/AUX.txt').readAsStringSync(), 'cloud');
      expect(local('Documents/A.txt').readAsStringSync(), 'upper');
      expect(local('Documents/a.txt').readAsStringSync(), 'lower');
      write('Documents/AUX.txt', 'edited');
      write('Documents/a.txt', 'lower edited');
      await engine.tick();
      expect(cloud.files['Documents/AUX.txt'], 'edited'.codeUnits);
      expect(cloud.files['Documents/a.txt'], 'lower edited'.codeUnits);
      for (final path in [
        'Documents/AUX.txt',
        'Documents/A.txt',
        'Documents/a.txt',
      ]) {
        expect(entry(path).status, 'current local');
        expect((await projected(path))['nameRefused'], isFalse);
      }
    },
    // Two cloud files that differ only by case cannot both exist on a
    // case-folding volume; that is decision #120's local clash rule for
    // names already on the server (spec #31 row 2, on mac-test).
    skip: foldsCase(Directory.systemTemp)
        ? 'needs a byte-exact volume: A.txt and a.txt both stay local here'
        : null,
  );
}
