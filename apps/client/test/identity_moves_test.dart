// Spec #33 I1: local moves by identity (decisions #139, #140; SC-058).
// A synchronized item gone from its path and one new item with the same
// local identity (volume:inode, link count 1) at another path is one cloud
// MOVE of the top item, at any depth and across folders: nothing uploaded
// or deleted again, file IDs kept. Acceptance rows 1, 3 (local rows), 4, 6
// and 7 on the VM host; the fake cloud records every request. Passes run without a
// watcher (a full scan each) unless the group says otherwise; the deferral
// group drives the bounds with a fake clock (SyncEngine.debugElapsed).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/commit_durability.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/identity_index.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/case_moves.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Records every request; folder deletion proven, so the old behaviour (a
/// delete plus a full re-upload) would show here.
class _Cloud extends FakeCloud {
  final calls = <String>[];

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
    return super.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    calls.add('DELETE $path');
    return super.deleteFile(path, etag: etag);
  }

  /// Called as each MOVE is sent (test seam).
  void Function()? beforeMove;

  /// Every MOVE fails (a server error) while set.
  bool failMoves = false;

  @override
  Future<void> move(String from, String to, {required String etag}) {
    beforeMove?.call();
    calls.add('MOVE $from -> $to');
    if (failMoves) {
      throw const CloudFailure('injected move failure', status: 503);
    }
    return super.move(from, to, etag: etag);
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

  /// An edit made on another device.
  void editElsewhere(String path, String text) => put(path, text);
}

/// The Linux binding, with test seams: a listed item may report another
/// inode (inode reuse, two rows on one identity), and the identity lookup
/// of spec #33 I3 may be switched on with a fake answer.
class _Fs extends NativeRootFs {
  _Fs()
    : super(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
        'Linux errno',
        const Duration(minutes: 60),
      );

  /// Path -> inode reported in its place.
  final Map<String, int> inodes = {};

  /// Path -> link count reported in its place.
  final Map<String, int> links = {};

  Map<String, dynamic> _seen(Map<String, dynamic> item) {
    final inode = inodes[item['path']], count = links[item['path']];
    return {
      ...item,
      'inode': ?inode,
      'links': ?count,
    };
  }

  /// Whole-directory listings of each descriptor ([scan], or a watch scan
  /// of '').
  final Map<int, int> walks = {};

  @override
  List<Map<String, dynamic>> scan(int fd) {
    walks[fd] = (walks[fd] ?? 0) + 1;
    return [for (final item in super.scan(fd)) _seen(item)];
  }

  @override
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive) {
    if (path.isEmpty) walks[root] = (walks[root] ?? 0) + 1;
    final found = super.watchScan(handle, root, path, recursive);
    return (
      items: [for (final item in found.items) _seen(item)],
      watches: found.watches,
    );
  }

  bool lookup = false;
  IdentityLocation Function(String identity)? answer;
  final lookups = <String>[];

  @override
  bool get locatesIdentity => lookup;

  @override
  IdentityLocation locateIdentity(int fd, int stageFd, String identity) {
    lookups.add(identity);
    return answer?.call(identity) ?? identityNotFound;
  }
}

/// Grouped commits (the macOS manifest mode, decision #136) on the VM host.
class _Groups implements CommitDurability {
  @override
  void barrier(String path) {}
  @override
  void flush(String path) {}
}

class _Crash implements Exception {}

/// The manifest, counting commit points; [failNext] of them throw.
class _Store extends Manifest {
  _Store(super.profile, {super.durability, super.groupCommits});
  int points = 0;
  int failNext = 0;

  @override
  void commitPoint() {
    points++;
    if (failNext > 0) {
      failNext--;
      throw const FileSystemException('injected commit point failure');
    }
    super.commitPoint();
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late _Store store;
  late _Cloud cloud;
  late SyncEngine engine;
  late _Fs fs;

  void start({bool watch = false, CommitDurability? durability}) {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-identity-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    fs = _Fs();
    tree = RootTree.setup(parent.path, 'root', fs)
      ..vmDirectory = '${fixture.path}/no-vm';
    store = _Store(
      Directory('${fixture.path}/profile'),
      durability: durability,
      groupCommits: durability != null,
    )..setSetting('retention', 'local');
    cloud = _Cloud()..foldersQualified = true;
    engine = SyncEngine(
      store,
      tree,
      cloud,
      watchers: watch ? const LinuxChangeWatchers() : null,
    );
  }

  var closed = false;
  tearDown(() {
    if (!closed) engine.close();
    closed = false;
    fixture.deleteSync(recursive: true);
  });
  String root(String path) => '${tree.root.path}/$path';
  void write(String path, String text) {
    File(root(path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text, flush: true);
  }

  void rename(String from, String to) {
    final type = FileSystemEntity.typeSync(root(from), followLinks: false);
    Directory(parentOf(root(to))).createSync(recursive: true);
    if (type == FileSystemEntityType.directory) {
      Directory(root(from)).renameSync(root(to));
    } else {
      File(root(from)).renameSync(root(to));
    }
  }

  String? remote(String path) =>
      cloud.files[path] == null ? null : utf8.decode(cloud.files[path]!);
  String disk(String path) => File(root(path)).readAsStringSync();
  Future<void> ticks([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await engine.tick();
    }
  }

  Map<String, int> fileIds() => Map.of(cloud.fileIds);
  Map<String, int> movedIds(
    Map<String, int> before,
    String from,
    String to,
  ) => {
    for (final e in before.entries)
      withinOrAt(from, e.key) ? renamedPath(from, to, e.key) : e.key: e.value,
  };

  Future<void> library() async {
    write('Photos/2026/Trip/a.jpg', 'a');
    write('Photos/2026/Trip/deep/b.jpg', 'b');
    write('Photos/2026/c.jpg', 'c');
    write('Docs/report.txt', 'report');
    write('Archive/keep.txt', 'keep');
    await ticks(2);
    expect(remote('Photos/2026/Trip/deep/b.jpg'), 'b');
    cloud.calls.clear();
  }

  group('row 1: a local move is one cloud MOVE', () {
    setUp(start);

    test('a file renamed into another folder', () async {
      await library();
      final ids = fileIds();
      rename('Docs/report.txt', 'Archive/Report 2026.txt');
      await ticks();
      expect(cloud.calls, ['MOVE Docs/report.txt -> Archive/Report 2026.txt']);
      expect(remote('Archive/Report 2026.txt'), 'report');
      expect(
        cloud.fileIds,
        movedIds(ids, 'Docs/report.txt', 'Archive/Report 2026.txt'),
      );
      expect(store.entries.containsKey('Docs/report.txt'), isFalse);
      final row = store.entries['Archive/Report 2026.txt']!;
      expect(row.status, 'current local');
      expect(row.fileId, ids['Docs/report.txt']);
      expect(store.operations.values.where((o) => o.kind == 'move'), isEmpty);
    });

    test('a deep subtree moved to another parent: one MOVE of its top, '
        'children rewritten, file IDs kept', () async {
      await library();
      final ids = fileIds();
      rename('Photos/2026/Trip', 'Archive/Trips/Trip 2026');
      // The new parent folder is created first; the move follows.
      await ticks(4);
      expect(cloud.calls, [
        'MKCOL Archive/Trips',
        'MOVE Photos/2026/Trip -> Archive/Trips/Trip 2026',
      ]);
      expect(remote('Archive/Trips/Trip 2026/deep/b.jpg'), 'b');
      expect(
        cloud.fileIds,
        movedIds(ids, 'Photos/2026/Trip', 'Archive/Trips/Trip 2026'),
      );
      for (final path in [
        'Archive/Trips/Trip 2026',
        'Archive/Trips/Trip 2026/a.jpg',
        'Archive/Trips/Trip 2026/deep',
        'Archive/Trips/Trip 2026/deep/b.jpg',
      ]) {
        expect(store.entries[path]?.status, 'current local', reason: path);
        expect(store.entries[path]!.etag, isNotNull, reason: path);
      }
      expect(
        store.entries.keys.where((k) => k.startsWith('Photos/2026/Trip')),
        isEmpty,
      );
    });

    test('a folder renamed while a child moves out of it: one MOVE each, '
        'the child after its folder', () async {
      await library();
      final ids = fileIds();
      rename('Photos/2026/Trip', 'Photos/2026/Holiday');
      rename('Photos/2026/Holiday/a.jpg', 'Archive/a.jpg');
      await ticks();
      expect(cloud.calls, [
        'MOVE Photos/2026/Trip -> Photos/2026/Holiday',
        'MOVE Photos/2026/Holiday/a.jpg -> Archive/a.jpg',
      ]);
      expect(remote('Archive/a.jpg'), 'a');
      expect(remote('Photos/2026/Holiday/deep/b.jpg'), 'b');
      expect(cloud.fileIds['Archive/a.jpg'], ids['Photos/2026/Trip/a.jpg']);
    });

    test('two folders swapped through a third name', () async {
      await library();
      rename('Docs', 'Tmp');
      rename('Archive', 'Docs');
      rename('Tmp', 'Archive');
      await ticks();
      // Both folder names stay present (holding each other's item), so
      // each file moves on its own: never a delete, never an upload.
      expect(cloud.calls.where((c) => !c.startsWith('MOVE')), isEmpty);
      await ticks(3);
      expect(remote('Archive/report.txt'), 'report');
      expect(remote('Docs/keep.txt'), 'keep');
    });

    test('moved on again before the cloud was reached: one MOVE to where '
        'it is now', () async {
      await library();
      final id = cloud.fileIds['Docs/report.txt'];
      cloud.online = false;
      rename('Docs/report.txt', 'Archive/a.txt');
      await engine.tick();
      rename('Archive/a.txt', 'Archive/b.txt');
      cloud.online = true;
      await ticks();
      expect(cloud.calls, ['MOVE Docs/report.txt -> Archive/b.txt']);
      expect(cloud.fileIds['Archive/b.txt'], id);
      expect(store.entries['Archive/b.txt']!.status, 'current local');
    });

    test('a #71 case-only rename is the special case', () async {
      await library();
      rename('Photos', 'photos');
      await ticks();
      expect(cloud.calls, ['MOVE Photos -> photos']);
    });

    test(
      'with folder watching (inotify pairs both sides in one batch)',
      () async {
        engine.close();
        fixture.deleteSync(recursive: true);
        start(watch: true);
        await engine.startWatching();
        await library();
        final ids = fileIds();
        rename('Photos/2026/Trip', 'Docs/Trip');
        for (var i = 0; i < 60 && remote('Docs/Trip/a.jpg') == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
        }
        expect(cloud.calls, ['MOVE Photos/2026/Trip -> Docs/Trip']);
        expect(cloud.fileIds, movedIds(ids, 'Photos/2026/Trip', 'Docs/Trip'));
        expect(engine.lastPass!.localScan, 'partial');
      },
    );
  });

  group('row 3: both sides change (local rows)', () {
    setUp(start);

    test('renamed here, edited in the cloud: the MOVE goes up, then the '
        'edit comes down at the new path', () async {
      await library();
      rename('Docs/report.txt', 'Archive/report.txt');
      cloud.editElsewhere('Docs/report.txt', 'edited elsewhere');
      await ticks();
      expect(cloud.calls, [
        'MOVE Docs/report.txt -> Archive/report.txt',
        'GET Archive/report.txt',
      ]);
      expect(disk('Archive/report.txt'), 'edited elsewhere');
      expect(store.entries['Archive/report.txt']!.conflict, isNull);
    });

    test('renamed and edited here, edited in the cloud: the MOVE, then the '
        'ordinary edit/edit conflict with both copies', () async {
      await library();
      rename('Docs/report.txt', 'Archive/report.txt');
      write('Archive/report.txt', 'edited here');
      cloud.editElsewhere('Docs/report.txt', 'edited elsewhere');
      await ticks();
      expect(cloud.calls.first, 'MOVE Docs/report.txt -> Archive/report.txt');
      expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
      final row = store.entries['Archive/report.txt']!;
      expect(
        row.conflict,
        'Both versions changed. Complete copies are retained.',
      );
      expect(disk('Archive/report.txt'), 'edited here');
      expect(row.remoteCopy, isNotNull);
    });

    test('renamed here, deleted in the cloud: kept and uploaded at its new '
        'name', () async {
      await library();
      rename('Docs/report.txt', 'Archive/report.txt');
      cloud.remove('Docs/report.txt');
      await ticks();
      expect(cloud.calls, ['PUT Archive/report.txt']);
      expect(remote('Archive/report.txt'), 'report');
      expect(disk('Archive/report.txt'), 'report');
      expect(store.entries['Archive/report.txt']!.status, 'current local');
    });

    test('a folder renamed here and deleted in the cloud: kept and created '
        'again at its new name', () async {
      await library();
      rename('Photos/2026/Trip', 'Trip');
      for (final path in cloud.files.keys.toList()) {
        if (path.startsWith('Photos/2026/Trip/')) cloud.remove(path);
      }
      cloud.directories.removeWhere((d) => d.startsWith('Photos/2026/Trip'));
      await ticks(4);
      expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
      expect(remote('Trip/a.jpg'), 'a');
      expect(remote('Trip/deep/b.jpg'), 'b');
      expect(disk('Trip/deep/b.jpg'), 'b');
    });

    test('renamed and edited here: one MOVE, then one upload of the new '
        'version', () async {
      await library();
      final id = cloud.fileIds['Docs/report.txt'];
      rename('Docs/report.txt', 'Docs/final.txt');
      write('Docs/final.txt', 'final');
      await ticks();
      expect(cloud.calls, [
        'MOVE Docs/report.txt -> Docs/final.txt',
        'PUT Docs/final.txt',
      ]);
      expect(cloud.fileIds['Docs/final.txt'], id);
    });
  });

  group('row 6: hard links, inode reuse and duplicate identities', () {
    setUp(start);

    test('a file with a second link never pairs', () async {
      await library();
      final outside = '${fixture.path}/outside-link';
      final made = Process.runSync('ln', [root('Docs/report.txt'), outside]);
      expect(made.exitCode, 0);
      await ticks(1);
      cloud.calls.clear();
      rename('Docs/report.txt', 'Docs/renamed.txt');
      await ticks();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
      expect(cloud.calls, contains('PUT Docs/renamed.txt'));
      expect(cloud.calls, contains('DELETE Docs/report.txt'));
    });

    test('a link count above 1 on the new side never pairs, even with the '
        'old identity recorded', () async {
      await library();
      expect(store.entries['Docs/report.txt']!.localIdentity, isNotNull);
      rename('Docs/report.txt', 'Docs/renamed.txt');
      Process.runSync('ln', [
        root('Docs/renamed.txt'),
        '${fixture.path}/outside-link',
      ]);
      await ticks();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
      expect(remote('Docs/renamed.txt'), 'report');
    });

    int links(String path) => int.parse(
      (Process.runSync('stat', ['-c', '%h', path]).stdout as String).trim(),
    );
    String inode(String path) =>
        (Process.runSync('stat', ['-c', '%i', path]).stdout as String).trim();

    /// A file that came down from the cloud: installed by hard link from its
    /// staging copy, so it has two links, one of them the engine's own.
    Future<void> downloaded() async {
      cloud.put('Docs/down.txt', 'from another device');
      await ticks(2);
      expect(disk('Docs/down.txt'), 'from another device');
      expect(links(root('Docs/down.txt')), 2);
      cloud.calls.clear();
    }

    test('a downloaded file (its second link in staging) renamed is one '
        'MOVE', () async {
      await library();
      await downloaded();
      final id = cloud.fileIds['Docs/down.txt'];
      rename('Docs/down.txt', 'Archive/down.txt');
      await ticks();
      expect(cloud.calls, ['MOVE Docs/down.txt -> Archive/down.txt']);
      expect(cloud.fileIds['Archive/down.txt'], id);
    });

    test('a downloaded file the user also hard-linked elsewhere (effective '
        'link count 2) never pairs', () async {
      await library();
      await downloaded();
      Process.runSync('ln', [
        root('Docs/down.txt'),
        '${fixture.path}/outside-link',
      ]);
      rename('Docs/down.txt', 'Archive/down.txt');
      await ticks();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
      expect(cloud.calls, contains('DELETE Docs/down.txt'));
      expect(remote('Archive/down.txt'), 'from another device');
    });

    test(
      'a quiet pass among 10,000 staged files stats and walks no staging',
      () async {
        await library();
        await downloaded();
        for (var i = 0; i < 10000; i++) {
          File('${tree.staging.path}/download-quiet-$i').writeAsStringSync('x');
        }
        final stats = engine.stagingStats;
        final walks = fs.walks[tree.stageFd] ?? 0;
        await ticks();
        expect(engine.stagingStats, stats);
        expect(fs.walks[tree.stageFd] ?? 0, walks);
        expect(cloud.calls, isEmpty);
        expect(store.entries['Docs/down.txt']!.localIdentity, isNotNull);
      },
    );

    test(
      'an effective link count of 0 (root and staging alias) never pairs',
      () async {
        await library();
        await downloaded();
        // A second staging link the manifest claims, while the scan reports
        // the root file with only two links: both look like the engine's own.
        final node = inode(root('Docs/down.txt'));
        final staged = tree.staging
            .listSync()
            .whereType<File>()
            .where((f) => inode(f.path) == node)
            .single;
        final record = store.operations.values.firstWhere(
          (o) =>
              o.kind == 'artifact' &&
              o.data['name'] == staged.uri.pathSegments.last,
        );
        Process.runSync('ln', [staged.path, '${tree.staging.path}/alias']);
        store.operations['test-alias'] =
            Operation(
                'test-alias',
                'artifact',
                'Docs/down.txt',
                staged: '${tree.staging.path}/alias',
                phase: 'complete',
              )
              ..data = {
                'role': 'download',
                'name': 'alias',
                'identity': record.data['identity'],
              };
        store.save();
        rename('Docs/down.txt', 'Archive/down.txt');
        fs.links['Archive/down.txt'] = 2;
        await ticks();
        expect(engine.stagingStats, greaterThan(0));
        expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
        expect(remote('Archive/down.txt'), 'from another device');
      },
    );

    test(
      'a manifest claim with no staging link on disk discounts nothing',
      () async {
        await library();
        await downloaded();
        // The staging copy goes (the record that claims it stays), and the
        // user links the file elsewhere: two links, neither the engine's.
        final node = inode(root('Docs/down.txt'));
        final staged = tree.staging
            .listSync()
            .whereType<File>()
            .where((f) => inode(f.path) == node)
            .single;
        final name = staged.uri.pathSegments.last;
        staged.deleteSync();
        expect(
          store.operations.values.any((o) => o.staged?.endsWith(name) ?? false),
          isTrue,
          reason: 'the manifest still claims the staging copy',
        );
        Process.runSync('ln', [
          root('Docs/down.txt'),
          '${fixture.path}/outside-link',
        ]);
        expect(links(root('Docs/down.txt')), 2);
        rename('Docs/down.txt', 'Archive/down.txt');
        await ticks();
        expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
        expect(remote('Archive/down.txt'), 'from another device');
      },
    );

    test('inode reuse: a deleted file and a new one on its inode end with '
        'the right contents on disk and in the cloud', () async {
      await library();
      final id = cloud.fileIds['Docs/report.txt'];
      final inode = int.parse(
        store.entries['Docs/report.txt']!.localIdentity!.split(':').last,
      );
      File(root('Docs/report.txt')).deleteSync();
      write('Archive/new.txt', 'new content');
      fs.inodes['Archive/new.txt'] = inode;
      await ticks();
      // Paired: the old cloud item moves to the new name, and the content
      // check uploads the new bytes as an edit (spec #33 Identity).
      expect(cloud.calls, [
        'MOVE Docs/report.txt -> Archive/new.txt',
        'PUT Archive/new.txt',
      ]);
      expect(remote('Archive/new.txt'), 'new content');
      expect(remote('Docs/report.txt'), isNull);
      expect(disk('Archive/new.txt'), 'new content');
      expect(File(root('Docs/report.txt')).existsSync(), isFalse);
      expect(cloud.fileIds['Archive/new.txt'], id);
    });

    test('two rows on one identity pair nothing, logged once', () async {
      final logged = <String>[];
      store.identities.log = logged.add;
      write('Docs/a.txt', 'a');
      write('Docs/b.txt', 'b');
      await ticks(1);
      final inode = int.parse(
        store.entries['Docs/a.txt']!.localIdentity!.split(':').last,
      );
      fs.inodes['Docs/b.txt'] = inode;
      await ticks(2);
      expect(logged, hasLength(1));
      expect(store.identities.duplicatesLogged, 1);
      cloud.calls.clear();
      rename('Docs/a.txt', 'Docs/c.txt');
      await ticks();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
      expect(cloud.calls, contains('DELETE Docs/a.txt'));
      expect(remote('Docs/c.txt'), 'a');
      expect(logged, hasLength(1), reason: 'logged once');
    });
  });

  group('row 7: a new path that cannot sync keeps the cloud item', () {
    setUp(start);

    test('a name decision #120 blocks: nothing deleted, the reason on the '
        'new row; renamed again to an allowed name, it moves', () async {
      await library();
      rename('Docs/report.txt', 'Docs/report: final.txt');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(remote('Docs/report.txt'), 'report');
      expect(
        store.entries['Docs/report: final.txt']!.status,
        nameNotAllowedStatus,
      );
      expect(store.entries['Docs/report.txt']!.status, movedHereStatus);
      rename('Docs/report: final.txt', 'Docs/report final.txt');
      await ticks();
      expect(cloud.calls, ['MOVE Docs/report.txt -> Docs/report final.txt']);
      expect(store.entries['Docs/report final.txt']!.status, 'current local');
    });

    test('a name clashing with a cloud sibling (#120): held, nothing '
        'deleted', () async {
      await library();
      cloud.put('Archive/Report.txt', 'another item');
      await ticks(1);
      cloud.calls.clear();
      rename('Docs/report.txt', 'Archive/report.txt');
      await ticks();
      expect(cloud.calls.where((c) => !c.startsWith('GET')), isEmpty);
      expect(remote('Docs/report.txt'), 'report');
      expect(store.entries['Archive/report.txt']!.status, nameNotAllowedStatus);
      expect(store.entries['Docs/report.txt']!.status, movedHereStatus);
    });

    test('moved back to its name: the row is ordinary again', () async {
      await library();
      rename('Docs/report.txt', 'Docs/a|b.txt');
      await ticks(2);
      expect(store.entries['Docs/report.txt']!.status, movedHereStatus);
      rename('Docs/a|b.txt', 'Docs/report.txt');
      await ticks(2);
      expect(cloud.calls, isEmpty);
      expect(store.entries['Docs/report.txt']!.status, 'current local');
    });

    test('an excluded name: the cloud item stays, nothing deleted', () async {
      await library();
      rename('Docs/report.txt', 'Docs/desktop.ini');
      await ticks();
      expect(cloud.calls, isEmpty);
      expect(remote('Docs/report.txt'), 'report');
      expect(
        store.entries['Docs/report.txt']!.status,
        "Moved to desktop.ini, which isn't synced",
      );
      // Renamed back to a synchronized name: an ordinary move.
      rename('Docs/desktop.ini', 'Docs/notes.txt');
      await ticks();
      expect(cloud.calls, ['MOVE Docs/report.txt -> Docs/notes.txt']);
      expect(store.entries['Docs/notes.txt']!.status, 'current local');
    });

    test(
      'a folder moved to a blocked name keeps its whole cloud subtree',
      () async {
        await library();
        rename('Photos/2026/Trip', 'Photos/2026/Trip?');
        await ticks();
        expect(cloud.calls, isEmpty);
        expect(remote('Photos/2026/Trip/deep/b.jpg'), 'b');
      },
    );
  });

  group('row 4: unpaired removals on partial passes (fake clock)', () {
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
    });

    LocalWatcher watcher() => engine.watcher! as LocalWatcher;

    test('SC-058: the two sides of a rename in different passes are one '
        'MOVE, and the hold ends within the maximum delay', () async {
      final w = watcher();
      final clock = w.debugNow;
      w.debugNow = () => 0; // The new side stays queued, not yet in view.
      rename('Docs/a.txt', 'Other/b.txt');
      // The new side arrived in a later batch: queued, not yet matured.
      w.enqueue('Other/b.txt');
      engine.markDirty('Docs/a.txt'); // Only the old side is rescanned.
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(store.entries['Docs/a.txt']!.expectedPresent, isTrue);
      now += settings.quiet * 4;
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(
        cloud.calls,
        isEmpty,
        reason: 'past the quiet period, but the watcher is still busy',
      );
      expect(store.entries['Docs/a.txt']!.expectedPresent, isTrue);
      // The next pass is due no later than the maximum delay.
      expect(engine.nextLocalDeadline()!, lessThanOrEqualTo(settings.maxDelay));
      w.debugNow = clock; // The other side reaches the view.
      for (var i = 0; i < 30 && remote('Other/b.txt') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
      expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
      expect(now, lessThan(settings.maxDelay));
    });

    test('no other side: the delete follows the quiet period', () async {
      File(root('Docs/a.txt')).renameSync('${fixture.path}/outside.txt');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(store.entries['Docs/a.txt']!.expectedPresent, isTrue);
      now += settings.quiet;
      await engine.tick();
      expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
      await engine.tick();
      expect(cloud.calls, ['DELETE Docs/a.txt']);
    });

    test('never past the maximum delay while the watcher stays busy', () async {
      final w = watcher();
      w.debugNow = () => 0;
      w.enqueue('Other/unrelated.txt');
      File(root('Docs/a.txt')).deleteSync();
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      now += settings.maxDelay - const Duration(milliseconds: 1);
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(store.entries['Docs/a.txt']!.expectedPresent, isTrue);
      now += const Duration(milliseconds: 1);
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
    });

    /// A rename whose other side is held back one pass, then delivered.
    Future<void> heldThenDelivered(String to, bool Function() done) async {
      final w = watcher();
      final clock = w.debugNow;
      w.debugNow = () => 0;
      rename('Docs/a.txt', to);
      w.enqueue(to);
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(store.entries['Docs/a.txt']!.expectedPresent, isTrue);
      w.debugNow = clock;
      for (var i = 0; i < 30 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
      expect(done(), isTrue);
    }

    // #78 review: a hold that became a park or a pending move must not keep
    // the next pass due at once.
    void idleAfterMaxDelay() {
      now += settings.maxDelay * 3;
      expect(engine.nextLocalDeadline()!, greaterThan(settings.maxDelay));
    }

    test('a hold that ends in a park lets the worker idle', () async {
      await heldThenDelivered(
        'Other/b|c.txt',
        () => store.entries['Docs/a.txt']!.status == movedHereStatus,
      );
      idleAfterMaxDelay();
      await engine.tick();
      idleAfterMaxDelay();
      expect(cloud.calls, isEmpty);
    });

    test(
      'a hold that ends in a move pending offline lets the worker idle',
      () async {
        cloud.online = false;
        await heldThenDelivered(
          'Other/b.txt',
          () => store.operations.values.any((o) => o.kind == 'move'),
        );
        idleAfterMaxDelay();
        cloud.online = true;
        await engine.tick();
        expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
      },
    );

    test('a hold that ends in a failing MOVE lets the worker idle', () async {
      cloud.failMoves = true;
      await heldThenDelivered('Other/b.txt', () => cloud.calls.isNotEmpty);
      expect(store.entries['Docs/a.txt']!.status, startsWith('rename pending'));
      idleAfterMaxDelay();
      cloud.failMoves = false;
      await engine.tick();
      expect(remote('Other/b.txt'), 'a');
      expect(cloud.calls.where((c) => !c.startsWith('MOVE')), isEmpty);
    });

    test('I3 seam: a lookup that finds the item makes it a MOVE in the same '
        'pass, without a hold', () async {
      final w = watcher();
      w.debugNow = () => 0;
      fs.lookup = true;
      fs.answer = (_) =>
          (place: IdentityPlace.inside, path: 'Other/b.txt', links: 1);
      rename('Docs/a.txt', 'Other/b.txt');
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(fs.lookups, hasLength(1));
      expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
      expect(now, Duration.zero);
    });

    test('I3 seam: a lookup that finds nothing is a delete at once', () async {
      final w = watcher();
      w.debugNow = () => 0;
      w.enqueue('Other/unrelated.txt');
      fs.lookup = true;
      File(root('Docs/a.txt')).deleteSync();
      engine.markDirty('Docs/a.txt');
      await engine.tick();
      expect(fs.lookups, hasLength(1));
      expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
      expect(now, Duration.zero);
    });

    // Spec #33 I3 on Linux, with a fake locator standing in for the macOS
    // and Windows export: only the old side of each change is rescanned,
    // and the watcher stays busy (its clock is frozen), so a hold lasts
    // until the maximum delay. A certain answer decides with the fake clock
    // still at zero; an uncertain one (decision #143) is held, then decided
    // by one full scan ([heldThenFullScan]).
    group('I3 lookup (fake locator)', () {
      setUp(() {
        watcher().debugNow = () => 0;
        watcher().enqueue('Other/unrelated.txt');
        fs.lookup = true;
      });

      IdentityLocation inside(String path, [int links = 1]) =>
          (place: IdentityPlace.inside, path: path, links: links);

      Future<void> onePass(String vanished) async {
        engine.markDirty(vanished);
        await engine.tick();
        expect(engine.lastPass!.localScan, 'partial');
      }

      test('found inside: a folder renamed is one MOVE in one pass', () async {
        write('Docs/deep/b.txt', 'b');
        for (var i = 0; i < 30 && remote('Docs/deep/b.txt') == null; i++) {
          watcher().debugNow = null;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
        }
        watcher().debugNow = () => 0;
        watcher().enqueue('Other/unrelated.txt');
        cloud.calls.clear();
        final ids = fileIds();
        final docs = store.entries['Docs']!.localIdentity!;
        fs.answer = (id) =>
            id == docs ? inside('Other/Docs 2026') : identityNotFound;
        rename('Docs', 'Other/Docs 2026');
        await onePass('Docs');
        expect(fs.lookups, [docs], reason: 'one lookup for the top item');
        expect(cloud.calls, ['MOVE Docs -> Other/Docs 2026']);
        expect(
          cloud.fileIds['Other/Docs 2026/deep/b.txt'],
          ids['Docs/deep/b.txt'],
        );
        expect(now, Duration.zero);
      });

      test('found outside the root (moved to the Trash): a delete in the same '
          'pass', () async {
        File(root('Docs/a.txt')).renameSync('${fixture.path}/Trash-a.txt');
        fs.answer = (_) => (place: IdentityPlace.outside, path: null, links: 0);
        await onePass('Docs/a.txt');
        expect(fs.lookups, hasLength(1));
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        await engine.tick();
        expect(cloud.calls, ['DELETE Docs/a.txt']);
        expect(now, Duration.zero);
      });

      test('not found (deleted): a delete in the same pass', () async {
        File(root('Docs/a.txt')).deleteSync();
        fs.answer = (_) => identityNotFound;
        await onePass('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        await engine.tick();
        expect(cloud.calls, ['DELETE Docs/a.txt']);
        expect(engine.uncertainAudits, 0);
        expect(now, Duration.zero);
      });

      // Decision #143: every other answer is uncertain. The removal is held
      // exactly as on Linux (the watcher stays busy here, so until the
      // maximum delay), it is never deleted on a partial pass, and when the
      // hold ends one full scan is asked for, which decides at once. Neither
      // the hold nor the request keeps the worker due at once.
      Future<void> heldThenFullScan(String vanished) async {
        final scans = engine.fullScans;
        // A new item the rescan found may go up; nothing is removed or moved.
        Iterable<String> removals() => cloud.calls.where(
          (c) => c.startsWith('DELETE') || c.startsWith('MOVE'),
        );
        await onePass(vanished);
        expect(fs.lookups, isNotEmpty);
        expect(
          store.entries[vanished]!.expectedPresent,
          isTrue,
          reason: 'an uncertain answer holds the removal',
        );
        expect(removals(), isEmpty);
        expect(engine.nextLocalDeadline()!, greaterThan(Duration.zero));
        now += settings.maxDelay - const Duration(milliseconds: 1);
        await onePass(vanished);
        expect(store.entries[vanished]!.expectedPresent, isTrue);
        expect(engine.uncertainAudits, 0, reason: 'held until maxDelay');
        expect(engine.nextLocalDeadline()!, greaterThan(Duration.zero));
        now += const Duration(milliseconds: 1);
        await onePass(vanished);
        expect(
          store.entries[vanished]!.expectedPresent,
          isTrue,
          reason: 'never deleted on a partial pass',
        );
        expect(removals(), isEmpty);
        expect(engine.uncertainAudits, 1, reason: 'one full scan asked for');
        expect(engine.nextLocalDeadline(), Duration.zero);
        expect(engine.fullScans, scans);
        await engine.tick();
        expect(engine.lastPass!.localScan, 'full');
        expect(engine.fullScans, scans + 1);
        // Settled: no second request and no wake loop (fake clock).
        for (var i = 0; i < 5; i++) {
          now += settings.maxDelay;
          await engine.tick();
        }
        expect(engine.uncertainAudits, 1);
        expect(engine.fullScans, scans + 1);
        expect(engine.nextLocalDeadline(), isNot(Duration.zero));
      }

      test('a lookup that throws: held, then a full scan deletes, never a '
          'crash', () async {
        File(root('Docs/a.txt')).deleteSync();
        fs.answer = (_) => throw const FileSystemException('injected');
        await heldThenFullScan('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        expect(cloud.calls, ['DELETE Docs/a.txt']);
        expect(engine.message, isNot(contains('injected')));
      });

      test('an uncertain answer (a native error or race) for an item that '
          'moved: held, then the full scan makes it one MOVE', () async {
        rename('Docs/a.txt', 'Other/b.txt');
        fs.answer = (_) => identityUncertain;
        await heldThenFullScan('Docs/a.txt');
        expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
        expect(remote('Other/b.txt'), 'a');
      });

      test('an uncertain answer for an item that is gone: held, then the '
          'full scan deletes', () async {
        File(root('Docs/a.txt')).deleteSync();
        fs.answer = (_) => identityUncertain;
        await heldThenFullScan('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        expect(cloud.calls, ['DELETE Docs/a.txt']);
      });

      test('found inside at a path that is not there (a stale answer): held, '
          'then the full scan deletes; nothing invented', () async {
        File(root('Docs/a.txt')).deleteSync();
        fs.answer = (_) => inside('Other/ghost.txt');
        await heldThenFullScan('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        expect(store.entries['Other/ghost.txt'], isNull);
        expect(cloud.calls, ['DELETE Docs/a.txt']);
      });

      test('found inside at a path that now holds a different item: held, '
          'then the full scan deletes; never paired', () async {
        File(root('Docs/a.txt')).deleteSync();
        write('Other/b.txt', 'another file');
        fs.answer = (_) => inside('Other/b.txt');
        await heldThenFullScan('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
        expect(cloud.calls, contains('DELETE Docs/a.txt'));
        expect(remote('Other/b.txt'), 'another file');
      });

      test('found inside but hard-linked by the user (effective link count '
          '2): held, then the full scan never pairs it', () async {
        rename('Docs/a.txt', 'Other/b.txt');
        Process.runSync('ln', [root('Other/b.txt'), root('Other/c.txt')]);
        fs.answer = (_) => inside('Other/b.txt', 2);
        await heldThenFullScan('Docs/a.txt');
        expect(store.entries['Docs/a.txt']?.expectedPresent ?? false, isFalse);
        expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
        expect(cloud.calls, contains('DELETE Docs/a.txt'));
      });

      test('found only in staging with another link left: held, then a MOVE '
          'when the other side arrives', () async {
        rename('Docs/a.txt', 'Other/b.txt');
        fs.answer = (_) => (place: IdentityPlace.staging, path: null, links: 2);
        await onePass('Docs/a.txt');
        expect(
          store.entries['Docs/a.txt']!.expectedPresent,
          isTrue,
          reason: 'where the other link is cannot be known: held',
        );
        expect(cloud.calls, isEmpty);
        fs.answer = (_) => inside('Other/b.txt');
        await onePass('Docs/a.txt');
        expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
        expect(engine.uncertainAudits, 0);
      });

      test('found only in staging until the hold ends: the full scan makes '
          'it one MOVE', () async {
        rename('Docs/a.txt', 'Other/b.txt');
        fs.answer = (_) => (place: IdentityPlace.staging, path: null, links: 2);
        await heldThenFullScan('Docs/a.txt');
        expect(cloud.calls, ['MOVE Docs/a.txt -> Other/b.txt']);
      });

      test('found only in staging, no link left but the engine\'s own: held, '
          'then the full scan deletes', () async {
        cloud.put('Docs/down.txt', 'from another device');
        watcher().debugNow = null;
        for (
          var i = 0;
          i < 30 && !File(root('Docs/down.txt')).existsSync();
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await engine.tick();
        watcher().debugNow = () => 0;
        watcher().enqueue('Other/unrelated.txt');
        expect(store.entries['Docs/down.txt']!.localIdentity, isNotNull);
        cloud.calls.clear();
        // The user's link goes; only the staging copy holds the inode.
        File(root('Docs/down.txt')).deleteSync();
        fs.answer = (_) => (place: IdentityPlace.staging, path: null, links: 1);
        await heldThenFullScan('Docs/down.txt');
        expect(
          store.entries['Docs/down.txt']?.expectedPresent ?? false,
          isFalse,
        );
        expect(cloud.calls, ['DELETE Docs/down.txt']);
      });

      test('several uncertain removals ask for one full scan', () async {
        File(root('Docs/a.txt')).deleteSync();
        File(root('Other/keep.txt')).deleteSync();
        fs.answer = (_) => identityUncertain;
        engine.markDirty('Other/keep.txt');
        await heldThenFullScan('Docs/a.txt');
        expect(fs.lookups.toSet(), hasLength(2));
        expect(cloud.calls.toSet(), {
          'DELETE Docs/a.txt',
          'DELETE Other/keep.txt',
        });
      });
    });
  });
  group('commit point (decisions #136, #137)', () {
    void renameThree() {
      rename('Docs/report.txt', 'Archive/r.txt');
      rename('Photos/2026/Trip', 'Archive/Trip');
      rename('Photos/2026/c.jpg', 'Docs/c.jpg');
    }

    Map<String, int> afterThree(Map<String, int> ids) => movedIds(
      movedIds(
        movedIds(ids, 'Docs/report.txt', 'Archive/r.txt'),
        'Photos/2026/Trip',
        'Archive/Trip',
      ),
      'Photos/2026/c.jpg',
      'Docs/c.jpg',
    );

    test(
      'one per pass for all its moves, before the first MOVE is sent',
      () async {
        start(durability: _Groups());
        await library();
        final seen = <(int, int)>[];
        cloud.beforeMove = () =>
            seen.add((store.unflushedCommits, store.flushes));
        renameThree();
        await engine.tick();
        expect(cloud.calls.where((c) => c.startsWith('MOVE')), hasLength(3));
        expect(seen, hasLength(3));
        expect(seen.first.$1, 0, reason: 'durable before the first send');
        expect(seen.map((v) => v.$2).toSet(), {
          seen.first.$2,
        }, reason: 'no full flush between the moves of one pass');
        expect(seen.last.$1, greaterThan(0), reason: 'rows rewritten, grouped');
      },
    );

    test('a failed commit point sends no MOVE that pass', () async {
      start();
      await library();
      renameThree();
      store.failNext = 1;
      await engine.tick();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), isEmpty);
      expect(
        store.operations.values.where((o) => o.kind == 'move'),
        hasLength(3),
      );
      await ticks();
      expect(cloud.calls.where((c) => c.startsWith('MOVE')), hasLength(3));
    });

    test(
      'a move planned during the sends gets its own commit point first',
      () async {
        start();
        await library();
        final points = <int>[];
        cloud.beforeMove = () => points.add(store.points);
        rename('Photos/2026/Trip', 'Photos/2026/Holiday');
        rename('Photos/2026/Holiday/a.jpg', 'Archive/a.jpg');
        await engine.tick();
        expect(cloud.calls, [
          'MOVE Photos/2026/Trip -> Photos/2026/Holiday',
          'MOVE Photos/2026/Holiday/a.jpg -> Archive/a.jpg',
        ]);
        expect(points[1], greaterThan(points[0]));
      },
    );

    for (final crashAt in [1, 2]) {
      test('a crash after it, before MOVE $crashAt is sent, replays every '
          'MOVE exactly once', () async {
        start();
        await library();
        final ids = fileIds();
        renameThree();
        var sends = 0;
        engine.barrier = (phase, op) {
          if (phase == 'move-before-dispatch' && ++sends == crashAt) {
            throw _Crash();
          }
        };
        await expectLater(engine.tick(), throwsA(isA<_Crash>()));
        expect(
          cloud.calls.where((c) => c.startsWith('MOVE')),
          hasLength(crashAt - 1),
        );
        // The process dies: what it held in memory is gone, and the next
        // start reads the manifest from disk.
        store.close();
        store = _Store(
          Directory('${fixture.path}/profile'),
          groupCommits: false,
        );
        engine = SyncEngine(store, tree, cloud);
        await ticks();
        final moves = cloud.calls.where((c) => c.startsWith('MOVE')).toList();
        expect(moves, hasLength(3));
        expect(moves.toSet(), {
          'MOVE Docs/report.txt -> Archive/r.txt',
          'MOVE Photos/2026/Trip -> Archive/Trip',
          'MOVE Photos/2026/c.jpg -> Docs/c.jpg',
        });
        expect(cloud.calls.where((c) => !c.startsWith('MOVE')), isEmpty);
        expect(cloud.fileIds, afterThree(ids));
        for (final path in ['Archive/r.txt', 'Archive/Trip/deep/b.jpg']) {
          expect(store.entries[path]?.status, 'current local', reason: path);
        }
        expect(store.operations.values.where((o) => o.kind == 'move'), isEmpty);
      });
    }
  });

  group('identity index', () {
    setUp(start);

    test('built at load and kept current on every row write', () async {
      write('Docs/a.txt', 'a');
      await ticks(2);
      final row = store.entries['Docs/a.txt']!;
      final identity = row.localIdentity!;
      expect(store.identities.pathOfLocal(identity), 'Docs/a.txt');
      expect(store.identities.pathOfFileId(row.fileId!), 'Docs/a.txt');
      rename('Docs/a.txt', 'Docs/b.txt');
      await ticks();
      expect(store.identities.pathOfLocal(identity), 'Docs/b.txt');
      expect(store.identities.pathOfFileId(row.fileId!), 'Docs/b.txt');
      engine.close();
      closed = true;
      final again = Manifest(Directory('${fixture.path}/profile'));
      try {
        expect(again.identities.pathOfLocal(identity), 'Docs/b.txt');
        expect(again.identities.pathOfFileId(row.fileId!), 'Docs/b.txt');
      } finally {
        again.close();
      }
    });

    test('released to Cloud-only, a row gives up its local identity', () async {
      await library();
      final row = store.entries['Docs/report.txt']!;
      final identity = row.localIdentity!;
      engine.setRetention('Docs', Retention.cloud);
      await ticks();
      expect(File(root('Docs/report.txt')).existsSync(), isFalse);
      expect(store.entries['Docs/report.txt']!.status, 'cloud-only');
      expect(store.entries['Docs/report.txt']!.localIdentity, isNull);
      expect(store.identities.pathOfLocal(identity), isNull);
      expect(cloud.calls.where((c) => c.startsWith('DELETE')), isEmpty);
    });

    test('a row without a version is nobody\'s identity', () {
      final index = IdentityIndex();
      final row = Entry('a', ItemKind.file)..localIdentity = 'v:1';
      index.update('a', row);
      expect(index.pathOfLocal('v:1'), isNull);
      row.etag = '"1"';
      index.update('a', row);
      expect(index.pathOfLocal('v:1'), 'a');
      index.update('a', null);
      expect(index.pathOfLocal('v:1'), isNull);
    });
  });
}

String parentOf(String path) => File(path).parent.path;
