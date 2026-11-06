// Decision #162 (restates #160): shared folders never pair by a file number
// alone. Scenarios from the identity review of PR #78 (ident-int-review-
// 637a29d), with the outcomes the decision rules.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sharing_engine_test.dart' show SharingCloud;

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late SharingCloud cloud;
  late SyncEngine engine;
  var now = Duration.zero;

  String rootPath() => '${fixture.path}/files/anj-cloud';
  File local(String path) => File('${rootPath()}/$path');
  String text(String path) => local(path).readAsStringSync();

  SyncEngine open() {
    store = Manifest(Directory('${fixture.path}/profile'));
    tree = RootTree(
      Directory(rootPath()),
      Directory('${fixture.path}/files/.stage'),
      NativeRootFs(),
    );
    return SyncEngine(store, tree, cloud)..debugElapsed = () => now;
  }

  Future<void> settle([int passes = 3]) async {
    for (var i = 0; i < passes; i++) {
      now += const Duration(minutes: 1);
      await engine.tick();
    }
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-identrev-');
    Directory(rootPath()).createSync(recursive: true);
    Directory('${fixture.path}/files/.stage').createSync(recursive: true);
    cloud = SharingCloud();
    now = Duration.zero;
    engine = open();
    store.setSetting('retention', 'local');
  });
  tearDown(() {
    try {
      engine.close();
    } on Object {
      // closed already
    }
    fixture.deleteSync(recursive: true);
  });

  /// Documents/Family shared out (f.txt), Documents/Private/bank.txt private.
  Future<void> ownLibrary() async {
    Directory('${rootPath()}/Documents/Family').createSync(recursive: true);
    Directory('${rootPath()}/Documents/Private').createSync(recursive: true);
    local('Documents/Family/f.txt').writeAsStringSync('family');
    local('Documents/Private/bank.txt').writeAsStringSync('bank statement');
    await engine.tick();
    await engine.tick();
    cloud.shared.add('Documents/Family');
    await engine.tick();
    expect(store.entries['Documents/Family']!.sharedOut, isTrue);
    expect(store.entries['Documents/Private/bank.txt']!.localIdentity, isNotNull);
  }

  test('M1: a deleted private file and a new file in a folder shared out on '
      'its reused number: no MOVE, the private file is deleted and the new '
      'one is created (the review\'s bank.txt -> Family/list.txt)', () async {
    await ownLibrary();
    final privateId = cloud.fileIds['Documents/Private/bank.txt'];
    local('Documents/Private/bank.txt').deleteSync();
    local('Documents/Family/list.txt').writeAsStringSync('shopping list');
    // The number the deleted file had, now the new file's (ext4, XFS).
    store.entries['Documents/Private/bank.txt']!.localIdentity = tree
        .statItem('Documents/Family/list.txt')!
        .identity!;
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.files['Documents/Private/bank.txt'], isNull);
    expect(cloud.fileIds['Documents/Family/list.txt'], isNot(privateId));
    expect(text('Documents/Family/list.txt'), 'shopping list');
  });

  test('M1: a deleted private folder and a new folder in a folder shared out '
      'on its reused number: no MOVE, nothing private listed in the share',
      () async {
    await ownLibrary();
    local('Documents/Private/bank2.txt').writeAsStringSync('statement 2');
    await engine.tick();
    await engine.tick();
    Directory('${rootPath()}/Documents/Private').deleteSync(recursive: true);
    Directory('${rootPath()}/Documents/Family/New').createSync();
    store.entries['Documents/Private']!.localIdentity = tree
        .statItem('Documents/Family/New')!
        .identity!;
    await engine.tick();
    expect(cloud.moves, isEmpty);
    await settle();
    expect(cloud.moves, isEmpty);
    expect(
      cloud.files.keys.where((v) => v.startsWith('Documents/Family/New/')),
      isEmpty,
    );
  });

  test('M1: a private file the user moves into a folder shared out (same size '
      'and time) is one MOVE; moved out again, one MOVE', () async {
    await ownLibrary();
    local('Documents/Private/bank.txt')
        .renameSync('${rootPath()}/Documents/Family/bank.txt');
    await engine.tick();
    await settle();
    expect(cloud.moves, [
      'Documents/Private/bank.txt -> Documents/Family/bank.txt',
    ]);
    local('Documents/Family/bank.txt')
        .renameSync('${rootPath()}/Documents/Private/bank.txt');
    await engine.tick();
    await settle();
    expect(cloud.moves.last,
        'Documents/Family/bank.txt -> Documents/Private/bank.txt');
    expect(cloud.deletes, 0);
  });

  test('M1: a file edited and moved into a folder shared out cannot prove '
      'itself: a delete plus a create', () async {
    await ownLibrary();
    local('Documents/Private/bank.txt')
        .renameSync('${rootPath()}/Documents/Family/bank.txt');
    local('Documents/Family/bank.txt')
        .writeAsStringSync('edited: a different size than before');
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.files['Documents/Private/bank.txt'], isNull);
    expect(
      text('Documents/Family/bank.txt'),
      'edited: a different size than before',
    );
  });

  test('M2: a folder shared out whose files are all Cloud-only, renamed: no '
      'MOVE, never deleted for everyone; restored, and the new name uploads '
      'as a new, unshared folder', () async {
    await ownLibrary();
    engine.setRetention('Documents/Family', Retention.cloud);
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(local('Documents/Family/f.txt').existsSync(), isFalse);
    Directory('${rootPath()}/Documents/Family')
        .renameSync('${rootPath()}/Documents/Family 2026');
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
    expect(
      store.operations.values.where((o) => o.kind == 'delete'),
      isEmpty,
    );
    expect(String.fromCharCodes(cloud.files['Documents/Family/f.txt']!),
        'family');
    expect(cloud.shared, contains('Documents/Family'));
    expect(Directory('${rootPath()}/Documents/Family').existsSync(), isTrue);
    expect(store.entries['Documents/Family/f.txt']!.etag, isNotNull);
    expect(cloud.directories, contains('Documents/Family 2026'));
    expect(cloud.shared, isNot(contains('Documents/Family 2026')));
  });

  test('M2: a known subfolder proves the rename: one MOVE', () async {
    await ownLibrary();
    Directory('${rootPath()}/Documents/Family/Sub').createSync();
    await engine.tick();
    await engine.tick();
    engine.setRetention('Documents/Family', Retention.cloud);
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(local('Documents/Family/f.txt').existsSync(), isFalse);
    // The subfolder stays on disk with its identity: the only proof.
    expect(Directory('${rootPath()}/Documents/Family/Sub').existsSync(), isTrue);
    expect(store.entries['Documents/Family/Sub']!.localIdentity, isNotNull);
    Directory('${rootPath()}/Documents/Family')
        .renameSync('${rootPath()}/Documents/Family 2026');
    await engine.tick();
    await settle();
    expect(cloud.moves, ['Documents/Family -> Documents/Family 2026']);
    expect(cloud.deletes, 0);
  });

  test('M2: its first 8 files deleted (deletes held), then renamed: the '
      'files still on disk prove it, one MOVE', () async {
    await ownLibrary();
    for (var i = 1; i <= 8; i++) {
      local('Documents/Family/a$i.txt').writeAsStringSync('a$i');
    }
    await engine.tick();
    await engine.tick();
    for (var i = 1; i <= 8; i++) {
      local('Documents/Family/a$i.txt').deleteSync();
    }
    await engine.tick();
    Directory('${rootPath()}/Documents/Family')
        .renameSync('${rootPath()}/Documents/Family 2026');
    await engine.tick();
    await settle();
    expect(cloud.moves, ['Documents/Family -> Documents/Family 2026']);
    expect(String.fromCharCodes(cloud.files['Documents/Family 2026/f.txt']!),
        'family');
    expect(cloud.directories, isNot(contains('Documents/Family')));
  });

  test('F-L1: a folder shared out deleted and an unrelated folder spelled '
      'the same up to case made (another file number): no MOVE, nothing '
      'private enters the share, and it is the owner\'s real delete', () async {
    await ownLibrary();
    Directory('${rootPath()}/Documents/Family').deleteSync(recursive: true);
    Directory('${rootPath()}/Documents/family').createSync();
    local('Documents/family/private.txt').writeAsStringSync('private');
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.files['Documents/Family/private.txt'], isNull);
    expect(cloud.shared, isNot(contains('Documents/family')));
    // Deleted for everyone after the holds (#157); this fake cannot delete
    // a folder, so the intent stays queued. Not restored.
    expect(
      store.operations.values
          .where((o) => o.kind == 'delete')
          .map((o) => o.path),
      contains('Documents/Family'),
    );
    expect(local('Documents/Family/f.txt').existsSync(), isFalse);
    expect(text('Documents/family/private.txt'), 'private');
  });

  test('F-M1: a folder shared out deleted and a case-variant folder made on '
      'its reused file number: no MOVE, the shared folder is restored, '
      'nothing private enters the share', () async {
    await ownLibrary();
    Directory('${rootPath()}/Documents/Family').deleteSync(recursive: true);
    Directory('${rootPath()}/Documents/family').createSync();
    local('Documents/family/private.txt').writeAsStringSync('private');
    // The number the shared folder had, now the new folder's (ext4, XFS).
    store.entries['Documents/Family']!.localIdentity = tree
        .statItem('Documents/family')!
        .identity!;
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
    expect(cloud.files['Documents/Family/private.txt'], isNull);
    expect(cloud.files['Documents/family/private.txt'], isNull);
    expect(text('Documents/Family/f.txt'), 'family');
    expect(cloud.shared, contains('Documents/Family'));
    expect(text('Documents/family/private.txt'), 'private');
  });

  test('D-H1: a genuine case-only rename of a Cloud-only folder shared out '
      '(same identity) is one MOVE', () async {
    await ownLibrary();
    engine.setRetention('Documents/Family', Retention.cloud);
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(local('Documents/Family/f.txt').existsSync(), isFalse);
    Directory('${rootPath()}/Documents/Family')
        .renameSync('${rootPath()}/Documents/FAMILY');
    await engine.tick();
    await settle();
    expect(cloud.moves, ['Documents/Family -> Documents/FAMILY']);
    expect(cloud.deletes, 0);
  });

  Future<void> cloudOnlySub(String folder) async {
    Directory('${rootPath()}/$folder').createSync(recursive: true);
    local('$folder/s.txt').writeAsStringSync('sub');
    await engine.tick();
    await engine.tick();
    engine.setRetention(folder, Retention.cloud);
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(local('$folder/s.txt').existsSync(), isFalse);
    expect(Directory('${rootPath()}/$folder').existsSync(), isTrue);
  }

  test('D-M1: a Cloud-only subfolder moved out of a folder shared out: no '
      'MOVE and no delete; restored in the share, the new folder is new',
      () async {
    await ownLibrary();
    await cloudOnlySub('Documents/Family/Sub');
    Directory('${rootPath()}/Documents/Family/Sub')
        .renameSync('${rootPath()}/Documents/Private/Sub');
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
    expect(
      store.operations.values.where((o) => o.kind == 'delete'),
      isEmpty,
    );
    expect(String.fromCharCodes(cloud.files['Documents/Family/Sub/s.txt']!),
        'sub');
    expect(Directory('${rootPath()}/Documents/Family/Sub').existsSync(),
        isTrue);
    expect(cloud.directories, contains('Documents/Private/Sub'));
  });

  test('D-M1: a Cloud-only private folder moved into a folder shared out: no '
      'MOVE and no delete; restored where it was, the new folder is new',
      () async {
    await ownLibrary();
    await cloudOnlySub('Documents/Private/Old');
    Directory('${rootPath()}/Documents/Private/Old')
        .renameSync('${rootPath()}/Documents/Family/Old');
    await engine.tick();
    await settle();
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
    expect(
      store.operations.values.where((o) => o.kind == 'delete'),
      isEmpty,
    );
    expect(String.fromCharCodes(cloud.files['Documents/Private/Old/s.txt']!),
        'sub');
    expect(cloud.files['Documents/Family/Old/s.txt'], isNull);
    expect(Directory('${rootPath()}/Documents/Private/Old').existsSync(),
        isTrue);
    expect(cloud.directories, contains('Documents/Family/Old'));
  });

  group('upgrade from a profile written before rows carried identities '
      '(6a84d1d / 41e1f82: the four per-folder settings, no row identity)',
      () {
    Future<void> placedShare() async {
      for (final folder in ['Documents', 'Documents/Taxes']) {
        cloud.directories.add(folder);
        cloud.versions[folder] = '"d-$folder"';
      }
      cloud.put('Documents/Taxes/a.txt', 'owner bytes');
      cloud.put('Documents/mine.txt', 'mine');
      cloud.setShare('Documents/Taxes', SharePermission.edit);
      cloud.incoming = [
        const IncomingShare(
          '7',
          'Documents/Taxes',
          'Alice',
          SharePermission.edit,
        ),
      ];
      for (var i = 0; i < 3; i++) {
        await engine.tick();
      }
      expect(text('Documents/Taxes/a.txt'), 'owner bytes');
    }

    String inode(String id) => id.substring(id.lastIndexOf(':') + 1);
    const legacyKeys = [
      'topFolderInodesV1',
      'sharedFolderInodeV1',
      'mountIdentitiesV1',
      'mountFilesV1',
    ];

    /// The profile as those builds left it, then a new process opens it.
    void legacyProfile() {
      final taxes = tree.statItem('Documents/Taxes')!.identity!;
      final docs = tree.statItem('Documents')!.identity!;
      final a = tree.statItem('Documents/Taxes/a.txt')!.identity!;
      for (final entry in store.entries.values) {
        entry.localIdentity = null;
      }
      store.setSetting(
        'topFolderInodesV1',
        jsonEncode({'Documents': inode(docs)}),
      );
      store.setSetting('sharedFolderInodeV1', '1');
      store.setSetting(
        'mountIdentitiesV1',
        jsonEncode({'Documents/Taxes': taxes}),
      );
      store.setSetting(
        'mountFilesV1',
        jsonEncode({
          'Documents/Taxes': {'a.txt': inode(a)},
        }),
      );
      store.save();
      engine.close();
      engine = open();
    }

    test('the records move onto their rows once and the keys are deleted; a '
        'share renamed during the upgrade is renamed for everyone', () async {
      await placedShare();
      legacyProfile();
      expect(store.entries['Documents/Taxes']!.localIdentity, isNull);
      Directory('${rootPath()}/Documents/Taxes')
          .renameSync('${rootPath()}/Documents/Taxes 2025');
      await engine.tick();
      for (final key in legacyKeys) {
        expect(store.setting(key), isNull, reason: key);
      }
      expect(store.entries['Documents']!.localIdentity, isNotNull);
      await settle();
      expect(cloud.deletes, 0);
      expect(cloud.left, isEmpty);
      expect(cloud.renamedForEveryone, [('7', 'Taxes 2025')]);
    });

    test('a top folder replaced during the upgrade is restored from the '
        'migrated record', () async {
      await placedShare();
      legacyProfile();
      Directory('${rootPath()}/Documents').deleteSync(recursive: true);
      Directory('${rootPath()}/Documents').createSync();
      await engine.tick();
      await settle();
      expect(cloud.deletes, 0);
      expect(text('Documents/mine.txt'), 'mine');
    });
  });
}
