import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Refuses chosen names the way the gateway's backstop does (spec #49).
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
      throw NameNotPortable(CloudNameProblem.untrimmed);
    }
    created.add(path);
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> mkdir(String path) async {
    attemptsBy[path] = (attemptsBy[path] ?? 0) + 1;
    if (refused.contains(path)) {
      throw NameNotPortable(CloudNameProblem.untrimmed);
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

  final residual = cantSyncNameStatus(CloudNameProblem.forbiddenName);

  test(
    'names decision #120 blocked sync verbatim with no row (spec #49 '
    'AC3)',
    () async {
      final names = ['CON', 'nul.txt', 'report.', 'a:b?.txt', 'x|y'];
      for (final name in names) {
        write('Documents/$name', name);
      }
      await engine.tick();
      await engine.tick();
      for (final name in names) {
        final path = 'Documents/$name';
        expect(cloud.files[path], utf8.encode(name), reason: path);
        expect(entry(path).status, 'current local', reason: path);
        final row = await projected(path);
        expect(row['cantSyncName'], isFalse);
        expect(row['presentationErrors'], isEmpty);
        expect(rowBadge(row), isNot(RowBadge.needsAttention));
      }
      expect(overall(), isNot(SyncStatus.attention));
    },
    skip: notOnWindows(
      'names such as CON and a:b? (windows_names_test proves AC4)',
    ),
  );

  test('AC8: rows an earlier client held under decision #120 resolve on the '
      'first pass, with no user action', () async {
    // A local trailing-space folder and a blocked name, held local-only.
    Directory('${tree.root.path}/Documents/Furniture Families ').createSync();
    write('Documents/Furniture Families /chair.rfa', 'chair');
    write('Documents/CON.txt', 'con');
    // A Cloud-only clash held back on a case-folding device.
    cloud.put('Documents/Notes.txt', 'upper');
    cloud.put('Documents/notes.txt', 'lower');
    const held = 'Name not allowed on other devices: rename to sync';
    store.entries
      ..['Documents/Furniture Families '] = (Entry(
        'Documents/Furniture Families ',
        ItemKind.directory,
      )..status = held)
      ..['Documents/Furniture Families /chair.rfa'] = (Entry(
        'Documents/Furniture Families /chair.rfa',
        ItemKind.file,
      )..status = 'pending: the folder name is not allowed on other devices')
      ..['Documents/CON.txt'] = (Entry('Documents/CON.txt', ItemKind.file)
        ..status = held)
      ..['Documents/notes.txt'] = (Entry('Documents/notes.txt', ItemKind.file)
        ..status =
            'Cloud only: another item here has the same name on this device. '
            'Rename one on another device to get both here');
    store.save();
    for (final entry in store.entries.values) {
      expect(isLegacyNameHold(entry.status), isTrue, reason: entry.path);
    }
    await engine.tick();
    await engine.tick();
    await engine.tick();
    for (final entry in store.entries.values) {
      expect(isLegacyNameHold(entry.status), isFalse, reason: entry.path);
      expect(isCantSyncName(entry.status), isFalse, reason: entry.path);
    }
    expect(
      cloud.files['Documents/Furniture Families/chair.rfa'],
      'chair'.codeUnits,
    );
    expect(cloud.files['Documents/CON.txt'], 'con'.codeUnits);
    expect(
      entry('Documents/Furniture Families/chair.rfa').status,
      'current local',
    );
    expect(entry('Documents/CON.txt').status, 'current local');
    if (!foldsCase(tree.root)) {
      expect(local('Documents/notes.txt').readAsStringSync(), 'lower');
      expect(local('Documents/Notes.txt').readAsStringSync(), 'upper');
    }
    expect(overall(), isNot(SyncStatus.attention));
  }, skip: notOnWindows('a folder name that ends in a space'));

  test('AC8 after a pass that is not an audit: the rows at the old name of '
      'a folder renamed in place are settled', () async {
    await engine.tick();
    Directory('${tree.root.path}/Documents/F ').createSync();
    write('Documents/F /c.rfa', 'c');
    store.entries
      ..['Documents/F '] = (Entry('Documents/F ', ItemKind.directory)
        ..status = 'Name not allowed on other devices: rename to sync')
      ..['Documents/F /c.rfa'] = (Entry('Documents/F /c.rfa', ItemKind.file)
        ..status = 'pending: the folder name is not allowed on other devices');
    store.save();
    await engine.tick();
    await engine.tick();
    expect(
      store.entries.values.where((e) => isLegacyNameHold(e.status)),
      isEmpty,
    );
    expect(cloud.files['Documents/F/c.rfa'], 'c'.codeUnits);
    expect(entry('Documents/F/c.rfa').status, 'current local');
  }, skip: notOnWindows('a folder name that ends in a space'));

  test('ordinary names and dotfiles upload unchanged', () async {
    final names = [
      'report.txt',
      '.bashrc',
      '.env',
      '.config',
      'CONSOLE.log',
      'COM10',
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
      expect((await projected(path))['cantSyncName'], isFalse);
    }
    expect(overall(), isNot(SyncStatus.attention));
  });

  test('R1: an untrimmed folder is renamed in place and its subtree syncs '
      'under the clean name; a `.part` file is skipped quietly', () async {
    Directory('${tree.root.path}/Documents/Furniture Families ').createSync();
    write('Documents/Furniture Families /chair.rfa', 'chair');
    write('Documents/ leading.txt', 'lead');
    write('Documents/movie.mkv.part', 'partial');
    final identity = tree
        .scanItems(includeExcluded: true)['Documents/Furniture Families ']!
        .identity;
    expect(identity, isNotNull);
    await engine.tick();
    await engine.tick();
    await engine.tick();
    expect(
      Directory('${tree.root.path}/Documents/Furniture Families ').existsSync(),
      isFalse,
    );
    // Renamed in place: the same folder, not a copy.
    expect(
      tree.scanItems()['Documents/Furniture Families']!.identity,
      identity,
    );
    expect(
      local('Documents/Furniture Families/chair.rfa').readAsStringSync(),
      'chair',
    );
    expect(cloud.directories, contains('Documents/Furniture Families'));
    expect(
      cloud.files['Documents/Furniture Families/chair.rfa'],
      'chair'.codeUnits,
    );
    expect(cloud.files['Documents/leading.txt'], 'lead'.codeUnits);
    expect(cloud.attemptsBy.keys.where((k) => k != k.trim()), isEmpty);
    expect(cloud.attemptsBy.keys.where((k) => k.contains(' /')), isEmpty);
    expect(cloud.attemptsBy['Documents/movie.mkv.part'], isNull);
    expect(local('Documents/movie.mkv.part').readAsStringSync(), 'partial');
    expect(store.entries.containsKey('Documents/movie.mkv.part'), isFalse);
    expect(overall(), isNot(SyncStatus.attention));
  }, skip: notOnWindows('a folder name that ends in a space'));

  test('a name equal to a cloud sibling\'s by case is its own item on Linux '
      '(spec #49 AC3)', () async {
    cloud.put('Documents/Notes.txt', 'cloud');
    await engine.tick();
    write('Documents/notes.txt', 'local');
    await engine.tick();
    await engine.tick();
    if (foldsCase(tree.root)) {
      // APFS: one item, so the write edits the downloaded file.
      expect(cloud.attemptsBy['Documents/notes.txt'], isNull);
      expect(cloud.files['Documents/Notes.txt'], 'local'.codeUnits);
      expect(entry('Documents/Notes.txt').status, 'current local');
      return;
    }
    expect(cloud.files['Documents/Notes.txt'], 'cloud'.codeUnits);
    expect(cloud.files['Documents/notes.txt'], 'local'.codeUnits);
    expect(entry('Documents/notes.txt').status, 'current local');
    expect(entry('Documents/Notes.txt').status, 'current local');
  });

  test('two new local names that differ by case both upload', () async {
    write('Documents/Photo.jpg', 'one');
    write('Documents/photo.jpg', 'two');
    await engine.tick();
    await engine.tick();
    if (foldsCase(tree.root)) {
      // APFS: one item, Photo.jpg, holding the second write.
      expect(cloud.created, contains('Documents/Photo.jpg'));
      expect(cloud.created, isNot(contains('Documents/photo.jpg')));
      expect(cloud.files['Documents/Photo.jpg'], 'two'.codeUnits);
      expect(store.entries.containsKey('Documents/photo.jpg'), isFalse);
      return;
    }
    expect(cloud.files['Documents/Photo.jpg'], 'one'.codeUnits);
    expect(cloud.files['Documents/photo.jpg'], 'two'.codeUnits);
  });

  test(
    'a gateway refusal is the residual row until the gateway accepts',
    () async {
      cloud.refused.add('Documents/plain.txt');
      write('Documents/plain.txt', 'v1');
      await engine.tick();
      await engine.tick();
      expect(cloud.files.containsKey('Documents/plain.txt'), isFalse);
      expect(
        entry('Documents/plain.txt').status,
        cantSyncNameStatus(CloudNameProblem.untrimmed),
      );
      expect((await projected('Documents/plain.txt'))['cantSyncName'], isTrue);
      cloud.refused.clear();
      engine.uploads.retryAll();
      await engine.tick();
      expect(cloud.files['Documents/plain.txt'], 'v1'.codeUnits);
      expect(entry('Documents/plain.txt').status, 'current local');
    },
  );

  test('a name no rule resolves is the one residual row; a folder of that '
      'name keeps its contents local', () async {
    // The folder sits apart from the file so a case-folding volume holds
    // both.
    write('Documents/.htaccess', 'rules');
    Directory('${tree.root.path}/Documents/Site/.HTACCESS')
        .createSync(recursive: true);
    write('Documents/Site/.HTACCESS/inside.txt', 'inside');
    await engine.tick();
    await engine.tick();
    expect(cloud.attemptsBy.keys.where((k) => k.contains('htaccess')), isEmpty);
    expect(cloud.attemptsBy.keys.where((k) => k.contains('HTACCESS')), isEmpty);
    for (final path in ['Documents/.htaccess', 'Documents/Site/.HTACCESS']) {
      expect(entry(path).status, residual, reason: path);
      final row = await projected(path);
      expect(row['cantSyncName'], isTrue);
      expect(row['presentationErrors'], [residual]);
      expect(libraryStatus(row), residual);
      expect(rowBadge(row), RowBadge.needsAttention);
    }
    expect(local('Documents/.htaccess').readAsStringSync(), 'rules');
    expect(
      local('Documents/Site/.HTACCESS/inside.txt').readAsStringSync(),
      'inside',
    );
    expect(overall(), SyncStatus.attention);
  });

  test(
    'Rename renames in place; the new name syncs and the old row ends',
    () async {
      write('Documents/.htaccess', 'bytes');
      Directory('${tree.root.path}/Documents/Site/.HTACCESS')
          .createSync(recursive: true);
      write('Documents/Site/.HTACCESS/child.txt', 'child');
      await engine.tick();
      expect(entry('Documents/.htaccess').status, residual);
      expect(
        await engine.renameLocal('Documents/.htaccess', 'htaccess.txt'),
        'Documents/htaccess.txt',
      );
      expect(
        await engine.renameLocal('Documents/Site/.HTACCESS', 'Rules'),
        'Documents/Site/Rules',
      );
      await engine.tick();
      await engine.tick();
      expect(local('Documents/.htaccess').existsSync(), isFalse);
      expect(local('Documents/htaccess.txt').readAsStringSync(), 'bytes');
      expect(cloud.files['Documents/htaccess.txt'], 'bytes'.codeUnits);
      expect(cloud.directories, contains('Documents/Site/Rules'));
      expect(cloud.files['Documents/Site/Rules/child.txt'], 'child'.codeUnits);
      for (final old in [
        'Documents/.htaccess',
        'Documents/Site/.HTACCESS',
        'Documents/Site/.HTACCESS/child.txt',
      ]) {
        final row = await projected(old);
        expect(visibleInLibrary(row), isFalse, reason: old);
      }
      expect(overall(), isNot(SyncStatus.attention));
    },
  );

  test('Rename refuses only empty, `/`, unresolvable, taken and excluded '
      'names, and items that can sync', () async {
    write('Documents/.htaccess', 'x');
    write('Documents/taken.txt', 'y');
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
    const path = 'Documents/.htaccess';
    await refuses(path, '', contains('Enter a name'));
    await refuses(path, 'a/b', contains('path separators'));
    await refuses(path, '.HTAccess', contains("can't sync"));
    await refuses(path, 'x.filepart', contains("can't sync"));
    await refuses(path, 'taken.txt', contains('already uses'));
    await refuses(path, '.DS_Store', contains('excluded'));
    await refuses(
      'Documents/taken.txt',
      'renamed.txt',
      contains('Only an item'),
    );
    expect(local(path).readAsStringSync(), 'x');
    // A name decision #120 refused is accepted, held under this device's
    // spelling (aux_.txt on Windows).
    expect(
      await engine.renameLocal(path, 'aux.txt'),
      'Documents/${NameRule.localName('aux.txt', const [], NameRule.current)}',
    );
  });

  test(
    'cloud files that differ only by case are kept and edited on Linux',
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
        expect((await projected(path))['cantSyncName'], isFalse);
      }
    },
    // On a case-folding volume the pair is R3 step 5's (macOS: a ` (2)`
    // local name), covered by the macOS layout and translation tests.
    skip: foldsCase(Directory.systemTemp)
        ? 'needs a byte-exact volume: A.txt and a.txt both stay local here'
        : null,
  );
}
