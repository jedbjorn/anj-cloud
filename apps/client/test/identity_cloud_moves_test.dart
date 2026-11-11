// Spec #33 I2: cloud moves by file ID (decision #139). A synchronized row
// missing from the listing and a listed item at a new path with the same
// file ID and kind is one move, applied here as one local rename of its top
// item through the guarded rename: nothing downloaded, the local identity
// (inode) kept. Acceptance rows 2, 3 (cloud rows) and 7 on the VM host; the fake
// cloud records every request and folders carry file IDs as Nextcloud's do.
// Passes run without a watcher (a full scan each) unless the group says
// otherwise; the partial-pass group drives the removal hold with a fake
// clock (SyncEngine.debugElapsed).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/commit_durability.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Records every request; folders have file IDs that follow a MOVE, and
/// `Shared/<owner>` folders are incoming shares (another storage).
class _Cloud extends FakeCloud {
  final calls = <String>[];
  final folderIds = <String, int>{};

  @override
  Future<List<RemoteItem>> snapshot() async => [
    for (final item in await super.snapshot())
      item.kind == ItemKind.directory
          ? RemoteItem(
              item.path,
              ItemKind.directory,
              item.etag,
              fileId: folderIds[item.path],
              permissions: item.path.startsWith('Shared/')
                  ? 'SRGDNVCK'
                  : 'RGDNVCK',
            )
          : item,
  ];

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    calls.add('PUT $path');
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    calls.add('GET $path');
    return super.download(path, target, etag: etag);
  }

  @override
  Future<void> mkdir(String path) {
    calls.add('MKCOL $path');
    return made(path);
  }

  /// A folder made on another device.
  Future<void> made(String path) async {
    await super.mkdir(path);
    folderIds.putIfAbsent(path, () => ++nextFileId);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    calls.add('DELETE $path');
    return super.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) {
    calls.add('MOVE $from -> $to');
    return _move(from, to, etag);
  }

  Future<void> _move(String from, String to, String etag) async {
    await super.move(from, to, etag: etag);
    for (final path in folderIds.keys.toList()) {
      if (path == from || path.startsWith('$from/')) {
        folderIds['$to${path.substring(from.length)}'] = folderIds.remove(
          path,
        )!;
      }
    }
  }

  /// A rename or move made on another device: file IDs and versions kept.
  Future<void> moveElsewhere(String from, String to) async {
    final parts = to.split('/')..removeLast();
    for (var i = 1; i <= parts.length; i++) {
      final parent = parts.take(i).join('/');
      if (!directories.contains(parent)) await made(parent);
    }
    await _move(from, to, versions[from]!);
  }

  @override
  bool get safeFolderDeletion => true;

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
      folderIds.remove(child);
      fileIds.remove(child);
      this.versions.remove(child);
    }
  }
}

/// The Linux binding, counting guarded renames and optionally failing one
/// after it is done (a crash before its rows are written).
class _Fs extends NativeRootFs {
  _Fs()
    : super(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
        'Linux errno',
        const Duration(minutes: 60),
      );

  final renames = <String>[];
  void Function()? afterRename;

  /// When set, every name this binding creates or renames to resolves the
  /// way a case- and normalization-insensitive volume (NTFS, default APFS)
  /// does: an existing sibling whose name differs only by case or
  /// normalization is that same item. [redirected] lists such writes.
  String? foldingRoot;
  final redirected = <String>[];

  String _resolve(String path) {
    final rootPath = foldingRoot;
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

  /// Called once before the next single-path stat of [statPath] (the
  /// engine's re-check just before a rename).
  String? statPath;
  void Function()? beforeStat;

  @override
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive) {
    if (handle == null && !recursive && path == statPath) {
      final hook = beforeStat;
      beforeStat = null;
      hook?.call();
    }
    return super.watchScan(handle, root, path, recursive);
  }

  @override
  void renameExclusive(int fd, String from, String to, String identity) {
    // Renaming an item to another spelling of its own name is allowed.
    final target = _resolve(to);
    super.renameExclusive(fd, from, target == from ? to : target, identity);
    renames.add('$from -> $to');
    afterRename?.call();
  }
}

class _Groups implements CommitDurability {
  @override
  void barrier(String path) {}
  @override
  void flush(String path) {}
}

class _Crash implements Exception {}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;
  late _Fs fs;

  void start({bool watch = false, CommitDurability? durability}) {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-cloud-moves-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    fs = _Fs();
    tree = RootTree.setup(parent.path, 'root', fs)
      ..vmDirectory = '${fixture.path}/no-vm';
    store = Manifest(
      Directory('${fixture.path}/profile'),
      durability: durability,
      groupCommits: durability != null,
    )..setSetting('retention', 'local');
    cloud = _Cloud();
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

  bool exists(String path) =>
      FileSystemEntity.typeSync(root(path), followLinks: false) !=
      FileSystemEntityType.notFound;
  String? remote(String path) =>
      cloud.files[path] == null ? null : utf8.decode(cloud.files[path]!);
  String disk(String path) => File(root(path)).readAsStringSync();
  Future<void> ticks([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await engine.tick();
    }
  }

  // The local identity the engine pairs by: device and inode.
  String identity(String path) {
    final out = Process.runSync('stat', ['-c', '%d:%i', root(path)]);
    return (out.stdout as String).trim();
  }

  Future<void> library() async {
    write('Photos/2026/Trip/a.jpg', 'a');
    write('Photos/2026/Trip/deep/b.jpg', 'b');
    write('Photos/2026/c.jpg', 'c');
    write('Docs/report.txt', 'report');
    write('Archive/keep.txt', 'keep');
    await ticks(3);
    expect(remote('Photos/2026/Trip/deep/b.jpg'), 'b');
    // Folder rows carry their cloud file IDs from the listing.
    expect(store.entries['Photos/2026/Trip']!.fileId, isNotNull);
    cloud.calls.clear();
    fs.renames.clear();
  }

  group('row 2: a cloud move is one local rename', () {
    setUp(start);

    test('a file moved into another folder: renamed here, nothing '
        'downloaded, the inode kept', () async {
      await library();
      final before = identity('Docs/report.txt');
      final id = store.entries['Docs/report.txt']!.fileId;
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/Report 2026.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, ['Docs/report.txt -> Archive/Report 2026.txt']);
      expect(exists('Docs/report.txt'), isFalse);
      expect(disk('Archive/Report 2026.txt'), 'report');
      expect(identity('Archive/Report 2026.txt'), before);
      final row = store.entries['Archive/Report 2026.txt']!;
      expect(row.status, 'current local');
      expect(row.fileId, id);
      expect(row.movedNote, isNull);
      expect(store.entries.containsKey('Docs/report.txt'), isFalse);
    });

    test(
      'a folder with 1,000 children renamed: one local rename, no GET',
      () async {
        for (var i = 0; i < 1000; i++) {
          write('Big/${i ~/ 100}/f$i.txt', 'f$i');
        }
        await ticks(3);
        expect(remote('Big/9/f999.txt'), 'f999');
        cloud.calls.clear();
        fs.renames.clear();
        final before = identity('Big');
        final child = identity('Big/3/f345.txt');
        await cloud.moveElsewhere('Big', 'Archive/Big 2026');
        await ticks();
        expect(fs.renames, ['Big -> Archive/Big 2026']);
        expect(cloud.calls, isEmpty);
        expect(identity('Archive/Big 2026'), before);
        expect(identity('Archive/Big 2026/3/f345.txt'), child);
        expect(
          store.entries.keys.where((k) => k == 'Big' || k.startsWith('Big/')),
          isEmpty,
        );
        final moved = store.entries.values
            .where((e) => e.path.startsWith('Archive/Big 2026/'))
            .toList();
        expect(moved.where((e) => e.kind == ItemKind.file), hasLength(1000));
        expect(
          moved.where((e) => e.status != 'current local'),
          isEmpty,
          reason: 'every row synchronized at its new path',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('a file written between the scan and the rename waits a pass, '
        'then moves and its edit uploads', () async {
      await library();
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      fs.statPath = 'Docs/report.txt';
      fs.beforeStat = () => write('Docs/report.txt', 'written meanwhile');
      await engine.tick();
      expect(fs.renames, isEmpty);
      expect(cloud.calls, isEmpty, reason: 'nothing deleted or fetched');
      expect(
        store.entries['Docs/report.txt']!.status,
        'rename pending: the item changed during the check',
      );
      await ticks();
      expect(fs.renames, ['Docs/report.txt -> Archive/r.txt']);
      expect(cloud.calls, ['PUT Archive/r.txt']);
      expect(remote('Archive/r.txt'), 'written meanwhile');
    });

    test('a deep subtree moved with a child moved out of it: one rename '
        'each, the child after its folder', () async {
      await library();
      await cloud.moveElsewhere('Photos/2026/Trip', 'Archive/Trip');
      await cloud.moveElsewhere('Archive/Trip/a.jpg', 'Docs/a.jpg');
      await ticks();
      expect(fs.renames, [
        'Photos/2026/Trip -> Archive/Trip',
        'Archive/Trip/a.jpg -> Docs/a.jpg',
      ]);
      expect(cloud.calls, isEmpty);
      expect(disk('Docs/a.jpg'), 'a');
      expect(disk('Archive/Trip/deep/b.jpg'), 'b');
      expect(store.entries['Docs/a.jpg']!.status, 'current local');
    });

    test('into a cloud folder this device lacks: the folder is created, '
        'then the item renamed into it', () async {
      await library();
      final before = identity('Docs/report.txt');
      await cloud.moveElsewhere('Docs/report.txt', 'New/Inner/report.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, ['Docs/report.txt -> New/Inner/report.txt']);
      expect(identity('New/Inner/report.txt'), before);
      expect(store.entries['New/Inner']!.etag, isNotNull);
      expect(store.entries['New/Inner/report.txt']!.status, 'current local');
    });

    test('a Cloud-only item only changes its row path', () async {
      await library();
      engine.setRetention('Archive', Retention.cloud);
      await ticks(2);
      expect(exists('Archive/keep.txt'), isFalse);
      cloud.calls.clear();
      fs.renames.clear();
      final id = store.entries['Archive/keep.txt']!.fileId;
      await cloud.moveElsewhere('Archive/keep.txt', 'Archive/kept.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, isEmpty);
      expect(store.entries.containsKey('Archive/keep.txt'), isFalse);
      final row = store.entries['Archive/kept.txt']!;
      expect(row.fileId, id);
      expect(row.expectedPresent, isFalse);
      expect(exists('Archive/kept.txt'), isFalse);
    });

    test(
      'rows without a file ID fall back to the #71 same-version rule',
      () async {
        await library();
        for (final path in ['Docs/report.txt', 'Archive/keep.txt']) {
          store.entries[path]!.fileId = null;
          cloud.fileIds.remove(path);
        }
        // A case-only rename of the same version still moves.
        await cloud.moveElsewhere('Docs/report.txt', 'Docs/Report.txt');
        // Any other rename without a file ID is a delete plus a download.
        await cloud.moveElsewhere('Archive/keep.txt', 'Archive/kept.txt');
        await ticks();
        expect(fs.renames, ['Docs/report.txt -> Docs/Report.txt']);
        expect(cloud.calls, ['GET Archive/kept.txt']);
        expect(disk('Archive/kept.txt'), 'keep');
      },
    );

    test('one commit point for every rename of the pass', () async {
      engine.close();
      fixture.deleteSync(recursive: true);
      start(durability: _Groups());
      await library();
      final seen = <(int, int)>[];
      fs.afterRename = () => seen.add((store.unflushedCommits, store.flushes));
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      await cloud.moveElsewhere('Photos/2026/Trip', 'Archive/Trip');
      await cloud.moveElsewhere('Photos/2026/c.jpg', 'Docs/c.jpg');
      // A new file: the scan commits its row in this pass, so the pass has
      // grouped, unflushed commits by the time the renames start.
      write('Archive/new.txt', 'new');
      final flushed = store.flushes;
      await engine.tick();
      expect(fs.renames, hasLength(3));
      expect(seen.first.$1, 0, reason: 'durable before the first rename');
      expect(
        seen.first.$2,
        flushed + 1,
        reason: 'one full flush taken for the renames, before the first',
      );
      expect(seen.map((v) => v.$2).toSet(), {
        seen.first.$2,
      }, reason: 'no full flush between the renames of one pass');
      expect(seen.last.$1, greaterThan(0), reason: 'rows rewritten, grouped');
    });

    test('a crash after a rename, before its rows are written: the next '
        'start pairs it here and finds it already moved', () async {
      await library();
      final before = identity('Docs/report.txt');
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      fs.afterRename = () => throw _Crash();
      await expectLater(engine.tick(), throwsA(isA<_Crash>()));
      fs.afterRename = null;
      // The process dies: the next start reads the manifest from disk.
      store.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      engine = SyncEngine(store, tree, cloud);
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(identity('Archive/r.txt'), before);
      expect(store.entries.containsKey('Docs/report.txt'), isFalse);
      expect(store.entries['Archive/r.txt']!.status, 'current local');
      expect(store.operations, isEmpty);
    });
  });

  group('row 2: a hard-linked file and a crash (accepted cost)', () {
    setUp(start);

    test('a crash between the rename and its rows: one GET to adopt it, and '
        'no row left at the old path', () async {
      await library();
      // A second name outside the root: the user's own hard link, so the
      // restart cannot prove the link count and never pairs it here.
      final outside = '${fixture.path}/report-link.txt';
      final made = Process.runSync('ln', [root('Docs/report.txt'), outside]);
      expect(made.exitCode, 0);
      await ticks(1);
      cloud.calls.clear();
      fs.renames.clear();
      final before = identity('Docs/report.txt');
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      fs.afterRename = () => throw _Crash();
      await expectLater(engine.tick(), throwsA(isA<_Crash>()));
      fs.afterRename = null;
      // The process dies before the rows are written.
      store.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      engine = SyncEngine(store, tree, cloud);
      await ticks();
      // Accepted (planner ruling): the item stays at the cloud name, and
      // adopting it costs one download of the same bytes, compared and
      // discarded; the file on disk is kept.
      expect(cloud.calls, ['GET Archive/r.txt']);
      expect(identity('Archive/r.txt'), before);
      expect(disk('Archive/r.txt'), 'report');
      expect(remote('Archive/r.txt'), 'report');
      expect(store.entries['Archive/r.txt']!.status, 'current local');
      expect(
        store.entries.containsKey('Docs/report.txt'),
        isFalse,
        reason: 'no "deleted" row lingers at the old path',
      );
      await ticks(1);
      expect(store.entries.containsKey('Docs/report.txt'), isFalse);
      expect(cloud.calls, ['GET Archive/r.txt']);
    });
  });

  group(
    'row 2: a crash under a top folder (the delete held by the settle)',
    () {
      setUp(start);

      test(
        'a hard-linked file renamed by a cloud move, then a crash before its '
        'rows: adopted by its bytes, never deleted and uploaded again (#80 '
        'delta review L1)',
        () async {
          var now = Duration.zero;
          engine.debugElapsed = () => now;
          write('Documents/Docs/report.txt', 'report');
          await ticks(3);
          final outside = '${fixture.path}/report-link.txt';
          expect(
            Process.runSync('ln', [
              root('Documents/Docs/report.txt'),
              outside,
            ]).exitCode,
            0,
          );
          await ticks(1);
          cloud.calls.clear();
          await cloud.moveElsewhere(
            'Documents/Docs/report.txt',
            'Documents/Archive/r.txt',
          );
          fs.afterRename = () => throw _Crash();
          await expectLater(engine.tick(), throwsA(isA<_Crash>()));
          fs.afterRename = null;
          store.close();
          store = Manifest(Directory('${fixture.path}/profile'));
          // A file with a second link may carry no recorded identity (no
          // staging claim proves it): only its bytes can say it is the item.
          store.entries['Documents/Docs/report.txt']!.localIdentity = null;
          store.save();
          engine = SyncEngine(store, tree, cloud)..debugElapsed = () => now;
          await ticks();
          now += engine.topDeleteSettle + const Duration(seconds: 1);
          await ticks();
          expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
          expect(cloud.calls.where((c) => c.startsWith('PUT')), isEmpty);
          expect(disk('Documents/Archive/r.txt'), 'report');
          expect(remote('Documents/Archive/r.txt'), 'report');
        },
      );
    },
  );

  group('row 3: both sides change (cloud rows)', () {
    setUp(start);

    test('edited here, renamed in the cloud: renamed here, then the edit '
        'uploads at the new path', () async {
      await library();
      write('Docs/report.txt', 'edited here');
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      await ticks();
      expect(fs.renames, ['Docs/report.txt -> Archive/r.txt']);
      expect(cloud.calls, ['PUT Archive/r.txt']);
      expect(remote('Archive/r.txt'), 'edited here');
      expect(remote('Docs/report.txt'), isNull);
    });

    Future<void> pendingUpload() async {
      await library();
      write('Docs/report.txt', 'edited here');
      cloud.failUpload = true;
      await engine.tick();
      cloud.failUpload = false;
      expect(
        store.operations.values.where(
          (o) => o.kind == 'upload' && o.path == 'Docs/report.txt',
        ),
        hasLength(1),
        reason: 'an upload left pending by a failed PUT',
      );
      cloud.calls.clear();
    }

    test('a pending upload moves with its row: sent at the new path, '
        'If-Match on the moved version', () async {
      await pendingUpload();
      final etag = cloud.versions['Docs/report.txt'];
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      expect(cloud.versions['Archive/r.txt'], etag);
      await ticks();
      expect(fs.renames, ['Docs/report.txt -> Archive/r.txt']);
      expect(cloud.calls, ['PUT Archive/r.txt']);
      expect(remote('Archive/r.txt'), 'edited here');
      expect(store.entries['Archive/r.txt']!.status, 'current local');
      expect(store.operations.values.where((o) => o.kind == 'upload'), isEmpty);
    });

    test('a pending upload, the item moved and edited in the cloud: the '
        'ordinary edit/edit conflict, both kept', () async {
      await pendingUpload();
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      cloud.put('Archive/r.txt', 'edited in the cloud');
      await ticks();
      expect(fs.renames, ['Docs/report.txt -> Archive/r.txt']);
      expect(cloud.calls.where((c) => c.startsWith('PUT')), isEmpty);
      expect(remote('Archive/r.txt'), 'edited in the cloud');
      expect(disk('Archive/r.txt'), 'edited here');
      final row = store.entries['Archive/r.txt']!;
      expect(row.conflict, isNotNull);
      expect(File(row.remoteCopy!).readAsStringSync(), 'edited in the cloud');
    });

    test('renamed here to A, in the cloud to B: the cloud name wins, the '
        'row says so once', () async {
      await library();
      final before = identity('Docs/report.txt');
      File(root('Docs/report.txt')).renameSync(root('Docs/A.txt'));
      await cloud.moveElsewhere('Docs/report.txt', 'Docs/B.txt');
      await ticks();
      expect(cloud.calls, isEmpty, reason: 'no MOVE, upload or download');
      expect(fs.renames, ['Docs/A.txt -> Docs/B.txt']);
      expect(exists('Docs/A.txt'), isFalse);
      expect(identity('Docs/B.txt'), before);
      expect(remote('Docs/B.txt'), 'report');
      final row = store.entries['Docs/B.txt']!;
      expect(row.status, 'current local');
      expect(row.movedNote, 'Renamed on another device to B.txt');
      expect(store.entries.containsKey('Docs/A.txt'), isFalse);
      expect((await projectEntry(engine, row))['presentationNotes'], [
        'Renamed on another device to B.txt',
      ]);
      // Shown once: a later move of the row replaces it.
      await cloud.moveElsewhere('Docs/B.txt', 'Docs/C.txt');
      await ticks();
      expect(store.entries['Docs/C.txt']!.movedNote, isNull);
    });

    test('a downloaded file (staging link) renamed on both sides: the cloud '
        'name wins', () async {
      await library();
      cloud.put('Docs/down.txt', 'from the cloud');
      await ticks(2);
      expect(cloud.calls, ['GET Docs/down.txt']);
      cloud.calls.clear();
      final before = identity('Docs/down.txt');
      File(root('Docs/down.txt')).renameSync(root('Docs/here.txt'));
      await cloud.moveElsewhere('Docs/down.txt', 'Docs/there.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, ['Docs/here.txt -> Docs/there.txt']);
      expect(identity('Docs/there.txt'), before);
      expect(
        store.entries['Docs/there.txt']!.movedNote,
        'Renamed on another device to there.txt',
      );
    });

    test('a folder renamed here and to another name in the cloud: one '
        'rename to the cloud name', () async {
      await library();
      Directory(root('Photos/2026/Trip')).renameSync(root('Photos/Local'));
      await cloud.moveElsewhere('Photos/2026/Trip', 'Archive/Cloud');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, ['Photos/Local -> Archive/Cloud']);
      expect(disk('Archive/Cloud/deep/b.jpg'), 'b');
      expect(
        store.entries['Archive/Cloud']!.movedNote,
        'Renamed on another device to Archive/Cloud',
      );
      expect(store.entries['Archive/Cloud/a.jpg']!.movedNote, isNull);
      expect(
        store.entries.keys.where((k) => k.startsWith('Photos/Local')),
        isEmpty,
      );
    });

    test('renamed here to a blocked name (parked), renamed in the cloud: '
        'the cloud name wins', () async {
      await library();
      File(root('Docs/report.txt')).renameSync(root('Docs/a:b.txt'));
      await ticks(2);
      expect(cloud.calls, isEmpty);
      expect(remote('Docs/report.txt'), 'report', reason: 'parked by I1');
      await cloud.moveElsewhere('Docs/report.txt', 'Docs/B.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, ['Docs/a:b.txt -> Docs/B.txt']);
      expect(store.entries.keys.where((k) => k.startsWith('Docs/')), [
        'Docs/B.txt',
      ]);
      expect(
        store.entries['Docs/B.txt']!.movedNote,
        'Renamed on another device to B.txt',
      );
      expect(store.entries['Docs/B.txt']!.status, 'current local');
    });

    test(
      'deleted here, renamed in the cloud: the delete follows the item',
      () async {
        await library();
        File(root('Docs/report.txt')).deleteSync();
        await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
        await ticks();
        expect(cloud.calls, ['DELETE Archive/r.txt']);
        expect(remote('Archive/r.txt'), isNull);
        expect(exists('Archive/r.txt'), isFalse);
        expect(store.operations, isEmpty);
      },
    );

    test('a folder deleted here, renamed in the cloud: the delete follows '
        'it', () async {
      await library();
      Directory(root('Photos/2026/Trip')).deleteSync(recursive: true);
      await cloud.moveElsewhere('Photos/2026/Trip', 'Archive/Trip');
      await ticks();
      expect(cloud.calls, ['DELETE Archive/Trip/']);
      expect(cloud.directories.contains('Archive/Trip'), isFalse);
      expect(exists('Archive/Trip'), isFalse);
    });
  });

  group('row 3 on partial passes (fake clock)', () {
    const settings = WatcherSettings(
      quiet: Duration(milliseconds: 150),
      maxDelay: Duration(seconds: 2),
    );
    var now = Duration.zero;

    setUp(() async {
      start(watch: true);
      engine.watcherSettings = settings;
      now = Duration.zero;
      engine.debugElapsed = () => now;
      await engine.startWatching();
      write('Docs/a.txt', 'a');
      write('Other/keep.txt', 'keep');
      for (var i = 0; i < 40 && cloud.files['Other/keep.txt'] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
      }
      cloud.calls.clear();
      fs.renames.clear();
    });

    test('deleted here while the cloud renames it: held, nothing fetched, '
        'then the delete follows it after the quiet period', () async {
      File(root('Docs/a.txt')).deleteSync();
      await cloud.moveElsewhere('Docs/a.txt', 'Other/b.txt');
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(cloud.calls, isEmpty, reason: 'neither downloaded nor deleted');
      expect(exists('Other/b.txt'), isFalse);
      now += settings.quiet;
      for (var i = 0; i < 3; i++) {
        engine.markDirty('Docs/a.txt');
        await engine.tick();
      }
      expect(cloud.calls, ['DELETE Other/b.txt']);
      expect(remote('Other/b.txt'), isNull);
    });

    test('a cloud rename on a watched root, into a new folder: one rename, '
        'the view and the watches follow', () async {
      final before = identity('Docs/a.txt');
      await cloud.moveElsewhere('Docs/a.txt', 'Fresh/b.txt');
      await ticks(2);
      expect(fs.renames, ['Docs/a.txt -> Fresh/b.txt']);
      expect(cloud.calls, isEmpty);
      expect(identity('Fresh/b.txt'), before);
      // The new folder is watched: a file made in it later is uploaded.
      write('Fresh/c.txt', 'c');
      for (var i = 0; i < 30 && remote('Fresh/c.txt') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        now += settings.quiet;
        await engine.tick();
      }
      expect(cloud.calls, ['PUT Fresh/c.txt']);
      cloud.calls.clear();
      // Later passes see nothing to do: the watcher's own events of the
      // rename are not a local move or a new item.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        now += settings.quiet;
        await engine.tick();
      }
      expect(cloud.calls, isEmpty);
      expect(store.entries['Fresh/b.txt']!.status, 'current local');
    });
  });

  group('row 7: a new name another item here holds keeps the item', () {
    setUp(start);

    // A name this device cannot hold (Win32 names, case folds): the group
    // after this one.

    test('deleted here while the cloud moved it onto a name another local '
        'item holds: the delete follows the item, nothing is downloaded, the '
        'local file stays and uploads as its own (#80 review L1)', () async {
      await library();
      File(root('Docs/report.txt')).deleteSync();
      write('Archive/r.txt', 'mine');
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      await ticks(4);
      expect(cloud.calls.where((c) => c.startsWith('GET')), isEmpty);
      expect(cloud.calls.first, 'DELETE Archive/r.txt');
      expect(cloud.calls, contains('PUT Archive/r.txt'));
      expect(disk('Archive/r.txt'), 'mine');
      expect(remote('Archive/r.txt'), 'mine');
      expect(store.entries['Archive/r.txt']!.conflict, isNull);
      expect(store.entries['Archive/r.txt']!.status, 'current local');
      expect(store.entries.containsKey('Docs/report.txt'), isFalse);
      expect(store.operations, isEmpty);
    });

    test('a new name another local item holds: kept at its path, the other '
        'item untouched', () async {
      await library();
      write('Archive/r.txt', 'mine');
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/r.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(fs.renames, isEmpty);
      expect(disk('Docs/report.txt'), 'report');
      expect(disk('Archive/r.txt'), 'mine');
      expect(remote('Archive/r.txt'), 'report');
      expect(store.entries['Docs/report.txt']!.status, serverNameClashStatus);
      // On every platform such a row is amber with its reason and the app
      // needs attention, until the clash is gone.
      SyncStatus overall() => deriveStatus(
        paused: false,
        offline: false,
        unpaired: false,
        message: engine.message,
        entries: store.entries.values,
        operations: store.operations.values,
      );
      expect(overall(), SyncStatus.attention);
      expect(
        (await projectEntry(
          engine,
          store.entries['Docs/report.txt']!,
        ))['presentationErrors'],
        [serverNameClashStatus],
      );
      // The other item goes: the move follows.
      File(root('Archive/r.txt')).deleteSync();
      await ticks();
      expect(fs.renames, ['Docs/report.txt -> Archive/r.txt']);
      expect(cloud.calls, isEmpty);
      expect(disk('Archive/r.txt'), 'report');
      expect(overall(), isNot(SyncStatus.attention));
    });
  });

  // A cloud move's target gets the same decision as a create or a download
  // (NameHolds): on a device that cannot hold the new name, the item stays
  // where it is with the reason, and nothing is renamed, created, deleted,
  // moved or uploaded for it. The filesystem here folds case as NTFS does,
  // so a wrong rename or folder creation lands inside the folded sibling.
  group('a new name this device cannot hold keeps the item', () {
    setUp(() {
      start();
      fs.foldingRoot = tree.root.path;
      engine
        ..holdsAnyName = false
        ..foldsCase = true;
    });

    List<String> listing(String folder) => [
      for (final e in Directory(root(folder)).listSync(followLinks: false))
        e.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();

    test(
      'a cloud rename to a name the platform refuses: not renamed, held '
      'with the reason, nothing sent; a later good name is followed',
      () async {
        await library();
        await cloud.moveElsewhere('Docs/report.txt', 'Docs/x.');
        await ticks(4);
        expect(fs.renames, isEmpty);
        expect(cloud.calls, isEmpty);
        expect(listing('Docs'), ['report.txt']);
        expect(disk('Docs/report.txt'), 'report');
        expect(remote('Docs/x.'), 'report');
        expect(
          store.entries['Docs/report.txt']!.status,
          serverNameNotAllowedStatus,
        );
        expect(store.entries['Docs/report.txt']!.conflict, isNull);
        expect(store.operations, isEmpty);
        // An edit here meanwhile stays here: nothing is uploaded over the
        // cloud item under either name.
        write('Docs/report.txt', 'edited while held');
        await ticks(3);
        expect(cloud.calls, isEmpty);
        expect(remote('Docs/x.'), 'report');
        // Renamed again in the cloud to a name this device can hold: followed
        // by one rename, and the edit then uploads as an edit of that item.
        await cloud.moveElsewhere('Docs/x.', 'Docs/fine.txt');
        await ticks(4);
        expect(fs.renames, ['Docs/report.txt -> Docs/fine.txt']);
        expect(listing('Docs'), ['fine.txt']);
        expect(cloud.calls, ['PUT Docs/fine.txt']);
        expect(remote('Docs/fine.txt'), 'edited while held');
        expect(store.entries['Docs/fine.txt']!.status, 'current local');
        expect(store.entries.containsKey('Docs/report.txt'), isFalse);
      },
    );

    test('a cloud rename onto a sibling that differs only by case: not '
        'renamed, held as a clash, both files untouched', () async {
      await library();
      write('Docs/x.txt', 'other');
      await ticks(3);
      cloud.calls.clear();
      await cloud.moveElsewhere('Docs/x.txt', 'Docs/Report.txt');
      await ticks(4);
      expect(fs.renames, isEmpty);
      expect(fs.redirected, isEmpty);
      expect(cloud.calls, isEmpty);
      expect(listing('Docs'), ['report.txt', 'x.txt']);
      expect(disk('Docs/report.txt'), 'report');
      expect(disk('Docs/x.txt'), 'other');
      expect(remote('Docs/report.txt'), 'report');
      expect(remote('Docs/Report.txt'), 'other');
      expect(store.entries['Docs/x.txt']!.status, serverNameClashStatus);
      expect(store.entries['Docs/report.txt']!.status, 'current local');
      expect(store.operations, isEmpty);
    });

    test('a cloud move into a folder held as a clash loser: not moved, no '
        'folder made, nothing lands in the kept sibling, and the following '
        'scans send nothing', () async {
      await library();
      await cloud.made('Archive/Docs');
      await cloud.made('Archive/docs');
      cloud.put('Archive/Docs/x.txt', 'kept folder');
      cloud.put('Archive/docs/y.txt', 'held folder');
      await ticks(3);
      expect(listing('Archive'), ['Docs', 'keep.txt']);
      expect(listing('Archive/Docs'), ['x.txt']);
      expect(store.entries['Archive/docs']!.status, serverNameClashStatus);
      cloud.calls.clear();
      fs.renames.clear();
      fs.redirected.clear();

      await cloud.moveElsewhere('Archive/keep.txt', 'Archive/docs/keep.txt');
      await ticks(5);
      expect(fs.renames, isEmpty);
      expect(fs.redirected, isEmpty, reason: 'nothing written through Docs');
      expect(cloud.calls, isEmpty);
      expect(listing('Archive'), ['Docs', 'keep.txt']);
      expect(listing('Archive/Docs'), ['x.txt']);
      expect(disk('Archive/keep.txt'), 'keep');
      expect(store.entries['Archive/keep.txt']!.status, serverFolderNameStatus);
      expect(store.entries['Archive/docs']!.status, serverNameClashStatus);
      expect(
        store.entries['Archive/docs/y.txt']!.status,
        serverFolderNameStatus,
      );
      // Only the record of the kept folder's download remains.
      expect([
        for (final o in store.operations.values)
          if (o.kind != 'artifact') '${o.kind} ${o.path}',
      ], isEmpty);
      // The cloud is as the other device left it.
      expect(remote('Archive/docs/keep.txt'), 'keep');
      expect(remote('Archive/docs/y.txt'), 'held folder');
      expect(remote('Archive/Docs/x.txt'), 'kept folder');
      expect(cloud.files.containsKey('Archive/keep.txt'), isFalse);
    });

    test('a cloud rename of the item itself in case only is still followed '
        '(the item is not its own sibling)', () async {
      await library();
      await cloud.moveElsewhere('Docs/report.txt', 'Docs/Report.txt');
      await ticks(3);
      expect(fs.renames, ['Docs/report.txt -> Docs/Report.txt']);
      expect(cloud.calls, isEmpty);
      expect(listing('Docs'), ['Report.txt']);
      expect(store.entries['Docs/Report.txt']!.status, 'current local');
    });
  });

  group('with the top folders (spec #34 P7)', () {
    setUp(start);

    test('Documents deleted here while the cloud renamed a file in it: '
        'restored under the cloud name, nothing deleted', () async {
      write('Documents/a.txt', 'alpha');
      await ticks(3);
      expect(remote('Documents/a.txt'), 'alpha');
      cloud.calls.clear();
      Directory(root('Documents')).deleteSync(recursive: true);
      await cloud.moveElsewhere('Documents/a.txt', 'Documents/b.txt');
      await ticks(4);
      expect(disk('Documents/b.txt'), 'alpha');
      expect(exists('Documents/a.txt'), isFalse);
      expect(store.entries.containsKey('Documents/a.txt'), isFalse);
      expect(store.entries['Documents/b.txt']!.restoring, isFalse);
      expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
      expect(remote('Documents/b.txt'), 'alpha');
    });

    test('the cloud renaming Documents (web UI) never renames it here; '
        'its contents follow the cloud (spec #34 P7)', () async {
      write('Documents/a.txt', 'alpha');
      await ticks(3);
      final before = identity('Documents/a.txt');
      fs.renames.clear();
      cloud.calls.clear();
      await cloud.moveElsewhere('Documents', 'Papers');
      await ticks(3);
      expect(fs.renames, ['Documents/a.txt -> Papers/a.txt']);
      expect(Directory(root('Documents')).existsSync(), isTrue);
      expect(disk('Papers/a.txt'), 'alpha');
      expect(identity('Papers/a.txt'), before);
      expect(cloud.calls, ['MKCOL Documents']);
    });

    test('a file the cloud moved from Documents to Music is renamed here, '
        'not downloaded again', () async {
      write('Documents/a.txt', 'alpha');
      await ticks(3);
      fs.renames.clear();
      cloud.calls.clear();
      await cloud.moveElsewhere('Documents/a.txt', 'Music/a.txt');
      await ticks(3);
      expect(fs.renames, ['Documents/a.txt -> Music/a.txt']);
      expect(cloud.calls, isEmpty);
      expect(disk('Music/a.txt'), 'alpha');
    });

    test('a deletion here held for the settle follows a cloud rename and '
        'keeps its settle clock (one hold, #91)', () async {
      var now = Duration.zero;
      engine.debugElapsed = () => now;
      write('Documents/a.txt', 'alpha');
      await ticks(3);
      cloud.calls.clear();
      File(root('Documents/a.txt')).deleteSync();
      await engine.tick();
      expect(cloud.calls, isEmpty, reason: 'held for the settle');
      now += const Duration(seconds: 8);
      await cloud.moveElsewhere('Documents/a.txt', 'Documents/b.txt');
      await engine.tick();
      expect(cloud.calls, isEmpty, reason: 'still within the settle');
      expect(
        store.operations.values.single.path,
        'Documents/b.txt',
        reason: 'the delete follows the item',
      );
      now = engine.topDeleteSettle + const Duration(seconds: 1);
      await engine.tick();
      expect(cloud.calls, ['DELETE Documents/b.txt']);
      expect(remote('Documents/b.txt'), isNull);
    });
  });

  group('never paired', () {
    setUp(start);

    Future<void> share() async {
      await cloud.made('Shared');
      await cloud.made('Shared/Bob');
      await ticks(2);
      cloud.calls.clear();
    }

    test('a move into an incoming share (a new file ID): delete plus '
        'download, as before', () async {
      await library();
      await share();
      cloud.remove('Docs/report.txt');
      cloud.put('Shared/Bob/report.txt', 'report');
      await ticks();
      expect(fs.renames, isEmpty);
      expect(cloud.calls, ['GET Shared/Bob/report.txt']);
      expect(exists('Docs/report.txt'), isFalse);
    });

    test('a file ID seen in another storage never crosses into it', () async {
      await library();
      await share();
      final id = cloud.fileIds['Docs/report.txt']!;
      cloud.remove('Docs/report.txt');
      cloud.put('Shared/Bob/report.txt', 'report');
      cloud.fileIds['Shared/Bob/report.txt'] = id;
      await ticks();
      expect(fs.renames, isEmpty);
      expect(cloud.calls, ['GET Shared/Bob/report.txt']);
    });

    test('a file ID listed at two new paths pairs neither', () async {
      await library();
      final id = cloud.fileIds['Docs/report.txt']!;
      await cloud.moveElsewhere('Docs/report.txt', 'Archive/one.txt');
      cloud.put('Archive/two.txt', 'report');
      cloud.fileIds['Archive/two.txt'] = id;
      await ticks();
      expect(fs.renames, isEmpty);
      expect(cloud.calls.toSet(), {
        'GET Archive/one.txt',
        'GET Archive/two.txt',
      });
    });

    test('a file ID two rows claim pairs nothing', () async {
      await library();
      final id = store.entries['Docs/report.txt']!.fileId;
      store.entries['Archive/keep.txt']!.fileId = id;
      await cloud.moveElsewhere('Docs/report.txt', 'Docs/r.txt');
      await ticks();
      expect(fs.renames, isEmpty);
      expect(cloud.calls, ['GET Docs/r.txt']);
    });
  });
}
