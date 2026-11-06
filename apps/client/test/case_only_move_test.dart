// SC-054: a rename that changes only case or Unicode normalization moves the
// item (one cloud MOVE, or one local rename for a cloud rename), never a
// deletion plus a create that clashes with the old name under decision #120.
// the VM host's filesystems are byte-exact; `_CaseInsensitiveFs` answers names the
// way APFS does, so the reverse direction is also checked as a Mac sees it.
// The MOVE itself against Nextcloud runs in deploy/case_move_fixture.py.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Records every namespace request; folder deletion proven (as the worker's
/// DAV client is), so the old behaviour is a delete plus a full re-upload.
class _Cloud extends FakeCloud {
  final calls = <String>[];

  /// The next move is applied, then its acknowledgement is lost.
  bool loseNextMoveAcknowledgement = false;

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    calls.add('PUT ${nfc(path)}');
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    calls.add('GET ${nfc(path)}');
    return super.download(path, target, etag: etag);
  }

  @override
  Future<void> mkdir(String path) {
    calls.add('MKCOL ${nfc(path)}');
    return super.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    calls.add('DELETE ${nfc(path)}');
    return super.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) async {
    calls.add('MOVE ${nfc(from)} -> ${nfc(to)}');
    await super.move(from, to, etag: etag);
    if (loseNextMoveAcknowledgement) {
      loseNextMoveAcknowledgement = false;
      throw const CloudFailure('moved; acknowledgement lost');
    }
  }

  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    calls.add('DELETE $path/');
    for (final child in {
      ...files.keys,
      ...directories,
    }.where((v) => v == path || v.startsWith('$path/')).toList()) {
      files.remove(child);
      directories.remove(child);
      this.versions.remove(child);
    }
  }

  /// A rename made by another device.
  Future<void> renameElsewhere(String from, String to) async {
    await super.move(from, to, etag: versions[from]!);
  }
}

/// The Linux binding, resolving every name it creates the way a case- and
/// normalization-insensitive volume (APFS) does: an existing sibling whose
/// name differs only by case or normalization is that same item.
class _CaseInsensitiveFs extends NativeRootFs {
  String? rootPath;

  /// Creates that landed on an existing item under another spelling.
  final redirected = <String>[];

  String _resolve(String path) {
    final rootPath = this.rootPath;
    if (rootPath == null) return path;
    var at = '';
    for (final part in path.split('/')) {
      final dir = Directory(at.isEmpty ? rootPath : '$rootPath/$at');
      String? hit;
      if (dir.existsSync()) {
        final key = NamePolicy.foldKey(part);
        for (final e in dir.listSync(followLinks: false)) {
          final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name == part) {
            hit = part;
            break;
          }
          if (NamePolicy.foldKey(name) == key) hit ??= name;
        }
      }
      at = at.isEmpty ? (hit ?? part) : '$at/${hit ?? part}';
    }
    if (at != path) redirected.add(path);
    return at;
  }

  @override
  void makeDir(int fd, String path) => super.makeDir(fd, _resolve(path));
  @override
  void makeDirExclusive(int fd, String path) =>
      super.makeDirExclusive(fd, _resolve(path));
  @override
  void install(int fd, String relative, String stage) =>
      super.install(fd, _resolve(relative), stage);
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;
  late _CaseInsensitiveFs insensitive;

  void start({bool caseInsensitive = false, bool watch = false}) {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-case-move-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    insensitive = _CaseInsensitiveFs();
    tree = RootTree.setup(
      parent.path,
      'root',
      caseInsensitive ? insensitive : NativeRootFs(),
    )..vmDirectory = '${fixture.path}/no-vm';
    insensitive.rootPath = tree.root.path;
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _Cloud()..foldersQualified = true;
    engine = SyncEngine(
      store,
      tree,
      cloud,
      watchers: watch ? const LinuxChangeWatchers() : null,
    );
  }

  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  String root(String path) => '${tree.root.path}/$path';
  void write(String path, String text) {
    File(root(path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text, flush: true);
  }

  String? remote(String path) =>
      cloud.files[path] == null ? null : utf8.decode(cloud.files[path]!);
  List<String> listed(String dir) => [
    for (final e in Directory(root(dir)).listSync()) e.path.split('/').last,
  ];
  Iterable<String> transfers() => cloud.calls.where((c) => !c.startsWith('M'));
  Future<void> ticks([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await engine.tick();
    }
  }

  Future<void> syncedPhotos() async {
    write('Photos/2026/a.jpg', 'a');
    write('Photos/2026/b.jpg', 'b');
    write('Photos/top.txt', 'top');
    await ticks(2);
    expect(remote('Photos/2026/a.jpg'), 'a');
    cloud.calls.clear();
  }

  group('a local rename', () {
    setUp(start);

    test('of a folder changing only case moves it once, children '
        'included, with nothing uploaded or deleted', () async {
      await syncedPhotos();
      final fileId = cloud.fileIds['Photos/2026/a.jpg'];
      Directory(root('Photos')).renameSync(root('photos'));
      await ticks();
      expect(cloud.calls, ['MOVE Photos -> photos']);
      expect(remote('photos/2026/a.jpg'), 'a');
      expect(remote('photos/2026/b.jpg'), 'b');
      expect(remote('photos/top.txt'), 'top');
      expect(cloud.files.keys.where((k) => k.startsWith('Photos')), isEmpty);
      expect(cloud.directories, containsAll(['photos', 'photos/2026']));
      expect(cloud.fileIds['photos/2026/a.jpg'], fileId);
      expect(store.entries.keys.where((k) => k.startsWith('Photos')), isEmpty);
      for (final path in ['photos', 'photos/2026', 'photos/2026/a.jpg']) {
        expect(store.entries[path]!.status, 'current local', reason: path);
        expect(store.entries[path]!.etag, isNotNull);
      }
      expect(store.operations.values.where((o) => o.kind == 'move'), isEmpty);
    });

    test('of a file changing only case moves it', () async {
      write('Docs/Report.txt', 'report');
      await ticks(2);
      cloud.calls.clear();
      File(root('Docs/Report.txt')).renameSync(root('Docs/report.txt'));
      await ticks();
      expect(cloud.calls, ['MOVE Docs/Report.txt -> Docs/report.txt']);
      expect(remote('Docs/report.txt'), 'report');
      expect(remote('Docs/Report.txt'), isNull);
      expect(store.entries['Docs/report.txt']!.status, 'current local');
      expect(store.entries.containsKey('Docs/Report.txt'), isFalse);
    });

    test('that also edits the file moves it, then uploads the edit '
        'against the moved version', () async {
      write('Docs/Report.txt', 'v1');
      await ticks(2);
      cloud.calls.clear();
      File(root('Docs/Report.txt')).renameSync(root('Docs/REPORT.txt'));
      write('Docs/REPORT.txt', 'v2');
      await ticks();
      expect(cloud.calls, [
        'MOVE Docs/Report.txt -> Docs/REPORT.txt',
        'PUT Docs/REPORT.txt',
      ]);
      expect(remote('Docs/REPORT.txt'), 'v2');
      expect(cloud.files.keys.where((k) => k.startsWith('Docs/R')), [
        'Docs/REPORT.txt',
      ]);
    });

    test(
      'changing only normalization is one name in the cloud '
      '(decision #138): nothing is sent and the new spelling is kept',
      () async {
        cloud.nfcOnly = true;
        write('Docs/café.txt', 'nfc');
        write('Docs/Résumés/cv.txt', 'cv');
        await ticks(2);
        final ids = Map.of(cloud.fileIds);
        cloud.calls.clear();
        File(root('Docs/café.txt')).renameSync(root('Docs/café.txt'));
        Directory(root('Docs/Résumés')).renameSync(root('Docs/Résumés'));
        await ticks(3);
        expect(cloud.calls, isEmpty);
        expect(cloud.fileIds, ids);
        expect(remote('Docs/café.txt'), 'nfc');
        expect(remote('Docs/Résumés/cv.txt'), 'cv');
        for (final path in [
          'Docs/café.txt',
          'Docs/Résumés',
          'Docs/Résumés/cv.txt',
        ]) {
          expect(store.entries[path]?.status, 'current local', reason: path);
          expect(store.entries[path]!.etag, isNotNull);
        }
        expect(store.entries.containsKey('Docs/café.txt'), isFalse);
        expect(listed('Docs'), unorderedEquals(['café.txt', 'Résumés']));
      },
    );

    test('changing case and normalization together moves the item to the '
        'NFC spelling of the new name', () async {
      cloud.nfcOnly = true;
      write('Docs/Café/menu.txt', 'menu');
      await ticks(2);
      cloud.calls.clear();
      Directory(root('Docs/Café')).renameSync(root('Docs/café'));
      await ticks(3);
      expect(cloud.calls, ['MOVE Docs/Café -> Docs/café']);
      expect(remote('Docs/café/menu.txt'), 'menu');
      expect(store.entries['Docs/café/menu.txt']!.status, 'current local');
      expect(listed('Docs'), ['café']);
    });

    test('of a folder and a child together moves both, the child keeping '
        'its file ID', () async {
      write('Photos/Top.txt', 'top');
      write('Photos/2026/a.jpg', 'a');
      await ticks(2);
      final id = cloud.fileIds['Photos/Top.txt'];
      cloud.calls.clear();
      File(root('Photos/Top.txt')).renameSync(root('Photos/top.txt'));
      Directory(root('Photos')).renameSync(root('photos'));
      await ticks(3);
      expect(cloud.calls, [
        'MOVE Photos -> photos',
        'MOVE photos/Top.txt -> photos/top.txt',
      ]);
      expect(remote('photos/top.txt'), 'top');
      expect(cloud.fileIds['photos/top.txt'], id);
      expect(store.entries['photos/top.txt']!.status, 'current local');
      expect(store.entries.containsKey('photos/Top.txt'), isFalse);
    });

    test('whose acknowledgement is lost is adopted from the listing', () async {
      await syncedPhotos();
      cloud.loseNextMoveAcknowledgement = true;
      Directory(root('Photos')).renameSync(root('photos'));
      await ticks();
      expect(cloud.calls, ['MOVE Photos -> photos']);
      expect(remote('photos/2026/a.jpg'), 'a');
      expect(store.entries['photos/2026/a.jpg']!.status, 'current local');
      expect(store.operations.values.where((o) => o.kind == 'move'), isEmpty);
    });

    test('undone before the cloud is reached sends nothing', () async {
      await syncedPhotos();
      cloud.online = false;
      Directory(root('Photos')).renameSync(root('photos'));
      await engine.tick();
      expect(
        store.operations.values.where((o) => o.kind == 'move'),
        hasLength(1),
      );
      Directory(root('photos')).renameSync(root('Photos'));
      cloud.online = true;
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(remote('Photos/2026/a.jpg'), 'a');
      expect(store.entries['Photos/2026/a.jpg']!.status, 'current local');
      expect(store.operations.values.where((o) => o.kind == 'move'), isEmpty);
    });

    test('already stalled by an earlier version (deletion unsent, new '
        'name held) becomes the move', () async {
      await syncedPhotos();
      Directory(root('Photos')).renameSync(root('photos'));
      // What earlier versions left: delete intents never dispatched (the
      // folder deletion unqualified) and the new spelling held as a clash.
      cloud.online = false;
      await engine.tick();
      for (final op
          in store.operations.values.where((o) => o.kind == 'move').toList()) {
        store.operations.remove(op.id);
      }
      for (final path in [
        'Photos',
        'Photos/2026',
        'Photos/2026/a.jpg',
        'Photos/2026/b.jpg',
        'Photos/top.txt',
      ]) {
        engine.intent(path, 'delete', etag: store.entries[path]!.etag);
        store.entries[path]!.expectedPresent = false;
      }
      store.entries['photos']!.status = nameNotAllowedStatus;
      store.save();
      cloud.online = true;
      await ticks();
      expect(cloud.calls, ['MOVE Photos -> photos']);
      expect(remote('photos/2026/b.jpg'), 'b');
      expect(store.entries['photos']!.status, 'current local');
      expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    });

    test('keeps decision #120 for a different item: a new local name that '
        'clashes with a Cloud-only one is held, not moved', () async {
      await cloud.mkdir('Docs');
      cloud.put('Docs/notes.txt', 'cloud');
      await ticks(1);
      engine.setRetention('Docs', Retention.cloud);
      await ticks(2);
      expect(File(root('Docs/notes.txt')).existsSync(), isFalse);
      cloud.calls.clear();
      write('Docs/Notes.txt', 'local');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(store.entries['Docs/Notes.txt']!.status, nameNotAllowedStatus);
      expect(remote('Docs/notes.txt'), 'cloud');
    });

    test('keeps decision #120 when both spellings are distinct items: a '
        'clashing sibling is still held', () async {
      cloud.put('Docs/A.txt', 'upper');
      await ticks(2);
      cloud.calls.clear();
      write('Docs/a.txt', 'lower');
      await ticks();
      if (foldsCase(tree.root)) {
        // APFS: the two spellings are one item, so the write edits A.txt.
        expect(listed('Docs'), ['A.txt']);
        expect(cloud.calls, ['PUT Docs/A.txt']);
        expect(remote('Docs/A.txt'), 'lower');
        expect(store.entries.containsKey('Docs/a.txt'), isFalse);
        expect(store.entries['Docs/A.txt']!.status, 'current local');
        return;
      }
      expect(cloud.calls, isEmpty);
      expect(store.entries['Docs/a.txt']!.status, nameNotAllowedStatus);
      expect(File(root('Docs/A.txt')).readAsStringSync(), 'upper');
    });
  });

  group('NFD names (decision #138)', () {
    setUp(() {
      start();
      cloud.nfcOnly = true;
    });

    test('a new NFD file and folder on Linux upload in NFC, keep their '
        'spelling here and settle', () async {
      await ticks(1);
      cloud.calls.clear();
      write('Notes/Résumé/café.txt', 'nfd');
      await ticks(2);
      expect(cloud.calls, [
        'MKCOL Notes',
        'MKCOL Notes/Résumé',
        'PUT Notes/Résumé/café.txt',
      ]);
      expect(remote('Notes/Résumé/café.txt'), 'nfd');
      expect(listed('Notes'), ['Résumé']);
      expect(listed('Notes/Résumé'), ['café.txt']);
      for (final path in ['Notes/Résumé', 'Notes/Résumé/café.txt']) {
        expect(store.entries[path]!.status, 'current local', reason: path);
      }
      cloud.calls.clear();
      await ticks(3);
      expect(cloud.calls, isEmpty, reason: 'no loop');
      expect(store.entries.keys.where((k) => k.contains('é')), isEmpty);
    });

    test('a new NFC sibling of a synced NFD folder is held: the cloud folder '
        'stays the synced one, nothing uploads into it', () async {
      write('Docs/Résumé/cv.txt', 'cv');
      await ticks(2);
      expect(remote('Docs/Résumé/cv.txt'), 'cv');
      cloud.calls.clear();
      write('Docs/Résumé/local.txt', 'local');
      await ticks(3);
      if (foldsNormalization(tree.root)) {
        // APFS: both spellings name the synced folder, so the file is a new
        // child of it and uploads; nothing is held.
        expect(listed('Docs'), hasLength(1));
        expect(cloud.calls, ['PUT Docs/R\u00e9sum\u00e9/local.txt']);
        expect(remote('Docs/R\u00e9sum\u00e9/local.txt'), 'local');
        expect(_held(store), isEmpty);
        return;
      }
      expect(cloud.calls, isEmpty);
      expect(remote('Docs/Résumé/local.txt'), isNull);
      expect(store.entries['Docs/Résumé']!.status, nameNotAllowedStatus);
      expect(
        store.entries['Docs/Résumé/local.txt']!.status,
        nameFolderPendingStatus,
      );
      final synced = store.entries['Docs/Résumé']!;
      expect(synced.conflict, isNull);
      expect(synced.status, 'current local');
      expect(store.entries['Docs/Résumé/cv.txt']!.status, 'current local');
    });

    test('a held NFD sibling of a synced NFC folder: a new cloud file '
        'lands in the synced folder, not the held one', () async {
      write('Docs/Résumé/cv.txt', 'cv');
      await ticks(2);
      write('Docs/Résumé/held.txt', 'held');
      await ticks(2);
      if (foldsNormalization(tree.root)) {
        // APFS: both spellings name the synced folder, so held.txt uploads
        // into it and the new cloud file lands beside it.
        expect(remote('Docs/R\u00e9sum\u00e9/held.txt'), 'held');
        expect(_held(store), isEmpty);
        cloud.calls.clear();
        cloud.put('Docs/R\u00e9sum\u00e9/new.txt', 'new');
        await ticks(2);
        expect(cloud.calls, ['GET Docs/R\u00e9sum\u00e9/new.txt']);
        expect(listed('Docs'), hasLength(1));
        expect(
          listed('Docs/R\u00e9sum\u00e9'),
          unorderedEquals(['cv.txt', 'held.txt', 'new.txt']),
        );
        return;
      }
      expect(store.entries['Docs/Résumé']!.status, nameNotAllowedStatus);
      cloud.calls.clear();
      cloud.put('Docs/Résumé/new.txt', 'new');
      await ticks(2);
      expect(cloud.calls, ['GET Docs/Résumé/new.txt']);
      expect(File(root('Docs/Résumé/new.txt')).readAsStringSync(), 'new');
      expect(listed('Docs/Résumé'), ['held.txt']);
      expect(remote('Docs/Résumé/held.txt'), isNull);
      expect(store.entries['Docs/Résumé/new.txt']!.status, 'current local');
    });

    test('a cloud NFC listing against a local NFD spelling is the same '
        'item: no upload or delete across passes', () async {
      await cloud.mkdir('Docs');
      await cloud.mkdir('Docs/Résumé');
      cloud
        ..put('Docs/café.txt', 'same')
        ..put('Docs/Résumé/cv.txt', 'cv')
        ..put('Docs/Résumé/cloud.txt', 'cloud');
      write('Docs/café.txt', 'same');
      write('Docs/Résumé/cv.txt', 'cv');
      cloud.calls.clear();
      await ticks(2);
      expect(
        cloud.calls.where(
          (c) =>
              !c.startsWith('GET') &&
              !const {
                'MKCOL Documents',
                'MKCOL Music',
                'MKCOL Videos',
              }.contains(c),
        ),
        isEmpty,
        reason: 'nothing uploaded, created, moved or deleted',
      );
      expect(listed('Docs'), unorderedEquals(['café.txt', 'Résumé']));
      expect(
        listed('Docs/Résumé'),
        unorderedEquals(['cv.txt', 'cloud.txt']),
        reason: 'a cloud-only child lands in the NFD folder',
      );
      expect(store.entries['Docs/café.txt']!.status, 'current local');
      expect(store.entries['Docs/café.txt']!.etag, isNotNull);
      cloud.calls.clear();
      await ticks(2);
      expect(cloud.calls, isEmpty);
      expect(remote('Docs/café.txt'), 'same');
      expect(store.entries.keys.where((k) => k.contains('é')), isEmpty);
    });
  });

  group('a cloud rename', () {
    test('of a folder changing only case renames the local folder once '
        '(Linux)', () async {
      start();
      await syncedPhotos();
      final before = File(root('Photos/2026/a.jpg')).statSync().modified;
      await cloud.renameElsewhere('Photos', 'photos');
      await ticks();
      expect(transfers(), isEmpty, reason: 'nothing downloaded or deleted');
      // By listing: on a case-folding volume `Photos` still resolves.
      expect(listed(''), contains('photos'));
      expect(listed(''), isNot(contains('Photos')));
      expect(File(root('photos/2026/a.jpg')).readAsStringSync(), 'a');
      expect(File(root('photos/2026/a.jpg')).statSync().modified, before);
      expect(store.entries.keys.where((k) => k.startsWith('Photos')), isEmpty);
      expect(store.entries['photos/2026/a.jpg']!.status, 'current local');
      expect(
        store.entries.values.where((e) => e.preservedCopies.isNotEmpty),
        isEmpty,
      );
    });

    test('of a file changing only case renames it, a different item at '
        'the new spelling is not mistaken for it', () async {
      start();
      write('Docs/Report.txt', 'report');
      write('Docs/Other.txt', 'other');
      await ticks(2);
      cloud.calls.clear();
      await cloud.renameElsewhere('Docs/Report.txt', 'Docs/report.txt');
      // A different item (new file ID) replaces Other.txt as OTHER.txt. On a
      // case-folding volume it cannot sit beside the kept Other.txt: that is
      // decision #120's local clash rule (spec #31 row 2, on mac-test), so
      // there only the rename is checked.
      final folds = foldsCase(tree.root);
      if (!folds) {
        cloud
          ..remove('Docs/Other.txt')
          ..put('Docs/OTHER.txt', 'new');
      }
      await ticks();
      expect(File(root('Docs/report.txt')).readAsStringSync(), 'report');
      expect(listed('Docs'), contains('report.txt'));
      expect(listed('Docs'), isNot(contains('Report.txt')));
      if (folds) {
        expect(transfers(), isEmpty);
        return;
      }
      expect(transfers(), ['GET Docs/OTHER.txt']);
      expect(store.entries['Docs/Other.txt']!.status, 'deleted remotely');
    });

    test('on a case-insensitive volume renames in place, never writing '
        'through the other spelling', () async {
      start(caseInsensitive: true);
      await syncedPhotos();
      await cloud.renameElsewhere('Photos', 'photos');
      await ticks();
      expect(insensitive.redirected, isEmpty);
      expect(transfers(), isEmpty);
      final names = [
        for (final e in Directory(tree.root.path).listSync())
          e.path.split('/').last,
      ];
      expect(names, contains('photos'));
      expect(names, isNot(contains('Photos')));
      expect(File(root('photos/2026/a.jpg')).readAsStringSync(), 'a');
      expect(store.entries['photos/top.txt']!.status, 'current local');
    });

    test('with folder watching, the watched view follows the rename', () async {
      start(watch: true);
      await engine.startWatching();
      (engine.watcher! as LocalWatcher)
        ..quiet = const Duration(milliseconds: 100)
        ..maxDelay = const Duration(seconds: 1);
      await syncedPhotos();
      expect(engine.watcher?.active, isTrue);
      await cloud.renameElsewhere('Photos', 'photos');
      await ticks();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await ticks();
      expect(transfers(), isEmpty);
      expect(remote('photos/2026/a.jpg'), 'a');
      expect(File(root('photos/2026/a.jpg')).readAsStringSync(), 'a');
      expect(store.entries['photos/2026/a.jpg']!.status, 'current local');
      expect(store.entries.keys.where((k) => k.startsWith('Photos')), isEmpty);
    });
  });
}

/// Entries held by a name clash (decision #120): none where names fold.
Iterable<String> _held(Manifest store) => store.entries.entries
    .where(
      (e) =>
          e.value.status == nameNotAllowedStatus ||
          e.value.status == nameFolderPendingStatus,
    )
    .map((e) => e.key);
