import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/trash_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/device_trash.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// A server with Nextcloud's trash behind the gateway's /trash/ routes: a
/// delete moves the item into the trash; a restore puts it back at its path,
/// or `name (restored).ext` when that is taken.
class _TrashCloud extends FakeCloud implements TrashApi {
  _TrashCloud(this.clock);
  final DateTime Function() clock;
  final trash =
      <String, ({String path, Map<String, List<int>> files, int deleted})>{};
  int trashDays = 7;
  int nextTrash = 900;

  @override
  bool get safeFolderDeletion => true;

  int get _now => clock().millisecondsSinceEpoch ~/ 1000;

  void _trash(String path) {
    final moved = <String, List<int>>{
      for (final key in files.keys.toList())
        if (key == path || p.posix.isWithin(path, key))
          key.substring(path.length): files[key]!,
    };
    trash['${++nextTrash}'] = (path: path, files: moved, deleted: _now);
    for (final key in moved.keys) {
      remove('$path$key');
    }
    directories.removeWhere((d) => d == path || p.posix.isWithin(path, d));
    versions.removeWhere((d, _) => d == path || p.posix.isWithin(path, d));
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    check();
    if (versions[path] != etag) {
      throw const CloudFailure('changed', status: 412);
    }
    deletes++;
    _trash(path);
  }

  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    check();
    _trash(path);
  }

  @override
  Future<ServerTrash?> listTrash() async {
    check();
    return ServerTrash(trashDays, [
      for (final MapEntry(key: id, value: item) in trash.entries)
        ServerTrashItem(
          id: id,
          path: item.path,
          folder: !item.files.containsKey(''),
          size: item.files.values.fold(0, (sum, bytes) => sum + bytes.length),
          deleted: item.deleted,
          expires: item.deleted + trashDays * 86400,
        ),
    ]);
  }

  @override
  Future<TrashRestore> restoreTrash(String id) async {
    check();
    final item = trash.remove(id);
    if (item == null) throw const CloudFailure('Not in Trash', status: 404);
    var target = item.path;
    if (versions.containsKey(target)) {
      final dir = p.posix.dirname(target);
      final name =
          '${p.posix.basenameWithoutExtension(target)} (restored)${p.posix.extension(target)}';
      target = dir == '.' ? name : '$dir/$name';
    }
    for (final MapEntry(key: suffix, value: bytes) in item.files.entries) {
      put('$target$suffix', String.fromCharCodes(bytes));
    }
    if (!item.files.containsKey('')) await mkdir(target);
    return TrashRestore(target, renamed: target != item.path);
  }

  @override
  Future<void> deleteTrash(String id) async {
    check();
    trash.remove(id);
  }

  @override
  Future<int> emptyTrash() async {
    check();
    final count = trash.length;
    trash.clear();
    return count;
  }
}

/// Spec #44: one-step delete into Trash, Undo, the device trash and its
/// 7-day purge, and the migration of earlier deletion rows.
void main() {
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  const dir = 'Documents/trash';
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _TrashCloud cloud;
  late SyncEngine engine;
  var now = DateTime.utc(2026, 11, 12, 12);

  setUp(() async {
    now = DateTime.utc(2026, 11, 12, 12);
    fixture = Directory.systemTemp.createTempSync('anj-device-trash-');
    tree = RootTree.setup(
      (Directory('${fixture.path}/files')..createSync()).path,
      'trash',
      NativeRootFs(),
    );
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _TrashCloud(() => now);
    engine = SyncEngine(store, tree, cloud)..wallClock = () => now;
    tree.ensureDirectory(dir);
    await engine.tick();
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  String sha(List<int> bytes) => sha256.convert(bytes).toString();
  Future<Map<String, dynamic>> row(String path) async =>
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(await projectEntry(engine, store.entries[path]!)))
            as Map,
      );
  Future<bool> visible(String path) async =>
      store.entries[path] != null && visibleInLibrary(await row(path));
  Iterable<Operation> ops(String kind) =>
      store.operations.values.where((o) => o.kind == kind);
  List<String> staged() =>
      tree.staging.listSync().map((f) => p.basename(f.path)).toList();

  Future<String> uploaded(String name, String text) async {
    final path = '$dir/$name';
    local(path).writeAsStringSync(text, flush: true);
    await engine.tick();
    await engine.tick();
    expect(cloud.files[path], text.codeUnits);
    return path;
  }

  /// The case that used to keep a Recovery row: no hash is recorded for the
  /// version being deleted.
  void forgetHash(String path) {
    store.entries[path]!
      ..remoteHash = null
      ..remoteHashEtag = null;
    store.save();
    expect(
      engine.artifacts.records.where((r) => r.path == path),
      isEmpty,
      reason: 'no record holds the version hash either',
    );
  }

  Map<String, Object?> delete(List<String> paths) =>
      engine.applyBulk('delete', [
        for (final path in paths)
          {
            'path': path,
            'kind': store.entries[path]!.kind.name,
            'selectionVersion': engine.selectionVersion(store.entries[path]!),
          },
      ]);

  group('AC1: delete is one step and leaves no row to dismiss', () {
    test('a file whose deleted-version hash is unknown: the row goes, its '
        'copy is in the device trash, the item in the server trash', () async {
      final path = await uploaded('unknown.txt', 'only this version');
      forgetHash(path);
      final result = delete([path]);
      expect(result['paths'], [path]);
      expect(result['at'], now.millisecondsSinceEpoch);
      // Gone from the library at once, before any pass.
      expect(await visible(path), isFalse);
      await engine.tick();
      await engine.tick();
      expect(await visible(path), isFalse);
      expect(ops('retained'), isEmpty);
      expect(engine.recovery.describe(path), isNull);
      final copy = engine.deviceTrash.items().single;
      expect(copy.path, path);
      expect(copy.at, now.millisecondsSinceEpoch);
      expect(
        File(ops('trash').single.staged!).readAsStringSync(),
        'only this version',
      );
      final server = (await cloud.listTrash())!.items.single;
      expect(server.path, path);
      // One entry per deletion: the device copy joins the server item.
      final listing = await engine.trashListing();
      final entries = (listing['entries'] as List).cast<Map>();
      expect(entries, hasLength(1));
      expect(entries.single['serverId'], server.id);
      expect(entries.single['deviceId'], copy.id);
      expect(entries.single['onlyDevice'], isFalse);
      expect(listing['note'], isNull);
    });

    test(
      'a file whose version is known: released, nothing on this device',
      () async {
        final path = await uploaded('known.txt', 'known version');
        delete([path]);
        await engine.tick();
        expect(await visible(path), isFalse);
        expect(ops('retained'), isEmpty);
        expect(ops('trash'), isEmpty);
        expect(staged().where((n) => n.startsWith('preserved-')), isEmpty);
        expect((await cloud.listTrash())!.items.single.path, path);
      },
    );

    test('a folder: it and its rows leave the library at once and go to the '
        'server trash', () async {
      final folder = '$dir/Album';
      tree.ensureDirectory(folder);
      await uploaded('Album/one.txt', 'one');
      await uploaded('Album/two.txt', 'two');
      delete([folder]);
      for (final path in [folder, '$folder/one.txt', '$folder/two.txt']) {
        expect(await visible(path), isFalse, reason: path);
      }
      await engine.tick();
      await engine.tick();
      for (final path in [folder, '$folder/one.txt', '$folder/two.txt']) {
        expect(await visible(path), isFalse, reason: path);
      }
      expect(Directory('${tree.root.path}/$folder').existsSync(), isFalse);
      expect(ops('retained'), isEmpty);
      final server = (await cloud.listTrash())!.items.single;
      expect((server.path, server.folder), (folder, true));
    });
  });

  group('AC2: Undo', () {
    test('while offline (pending intent): the delete is cancelled; same path, '
        'same bytes, and the server still matches', () async {
      final path = await uploaded('offline.txt', 'offline bytes');
      final before = sha(local(path).readAsBytesSync());
      cloud.online = false;
      final at = delete([path])['at'] as int;
      expect(await visible(path), isFalse);
      final undo = await engine.undoDelete([path], at, server: false);
      expect((undo['results'] as List).single, {
        'path': path,
        'result': 'restored',
        'to': path,
      });
      expect(ops('delete'), isEmpty);
      expect(await visible(path), isTrue);
      cloud.online = true;
      await engine.tick();
      await engine.tick();
      expect(sha(local(path).readAsBytesSync()), before);
      expect(sha(cloud.files[path]!), before);
      expect(cloud.deletes, 0);
      expect(cloud.trash, isEmpty);
      expect(await visible(path), isTrue);
    });

    test('after the server acknowledged: restored from the server trash with '
        'the same bytes, no "(restored)" name', () async {
      final path = await uploaded('acked.txt', 'acknowledged bytes');
      final before = sha(local(path).readAsBytesSync());
      final at = delete([path])['at'] as int;
      await engine.tick();
      expect(local(path).existsSync(), isFalse);
      expect(cloud.files.containsKey(path), isFalse);
      final undo = await engine.undoDelete([path], at);
      expect((undo['results'] as List).single['result'], 'restored');
      await engine.tick();
      await engine.tick();
      expect(sha(local(path).readAsBytesSync()), before);
      expect(sha(cloud.files[path]!), before);
      expect(cloud.trash, isEmpty);
      expect(await visible(path), isTrue);
      expect(local('$dir/acked (restored).txt').existsSync(), isFalse);
    });

    test(
      'after the server acknowledged a copy it could not prove: restored '
      'from the server, and the device copy is released as redundant',
      () async {
        final path = await uploaded('unproven.txt', 'unproven bytes');
        forgetHash(path);
        final at = delete([path])['at'] as int;
        await engine.tick();
        expect(engine.deviceTrash.items(), hasLength(1));
        await engine.undoDelete([path], at);
        await engine.tick();
        await engine.tick();
        expect(local(path).readAsStringSync(), 'unproven bytes');
        expect(engine.deviceTrash.items(), isEmpty);
        expect(staged().where((n) => n.startsWith('preserved-')), isEmpty);
      },
    );

    test(
      'a name taken meanwhile gets "(restored)"; nothing is overwritten',
      () async {
        final path = await uploaded('taken.txt', 'deleted bytes');
        final at = delete([path])['at'] as int;
        await engine.tick();
        local(path).writeAsStringSync('new file here', flush: true);
        await engine.tick();
        await engine.tick();
        final undo = await engine.undoDelete([path], at);
        final result = (undo['results'] as List).single as Map;
        expect(result['result'], 'renamed');
        expect(result['to'], '$dir/taken (restored).txt');
        await engine.tick();
        await engine.tick();
        expect(local(path).readAsStringSync(), 'new file here');
        expect(
          local('$dir/taken (restored).txt').readAsStringSync(),
          'deleted bytes',
        );
      },
    );

    test('an item no longer in Trash: says so and changes nothing', () async {
      final path = await uploaded('gone.txt', 'gone');
      final at = delete([path])['at'] as int;
      await engine.tick();
      await cloud.emptyTrash();
      final undo = await engine.undoDelete([path], at);
      final result = (undo['results'] as List).single as Map;
      expect(
        (result['result'], result['message']),
        ('failed', 'No longer in Trash'),
      );
      await engine.tick();
      expect(local(path).existsSync(), isFalse);
      expect(cloud.files.containsKey(path), isFalse);
    });
  });

  group('AC5: the device trash', () {
    Future<DeviceTrashItem> trashed(String name) async {
      final path = await uploaded(name, 'copy of $name');
      forgetHash(path);
      delete([path]);
      await engine.tick();
      return engine.deviceTrash.items().singleWhere((c) => c.path == path);
    }

    test('purged after exactly trash_days: kept at 6 days 23 hours, gone at '
        '7 days plus 1 second, and its space freed', () async {
      final copy = await trashed('purge.txt');
      final start = now;
      final name = p.basename(ops('trash').single.staged!);
      now = start.add(const Duration(days: 6, hours: 23));
      await engine.tick();
      expect(engine.deviceTrash.items(), hasLength(1));
      expect(staged(), contains(name));
      now = start.add(const Duration(days: 7));
      await engine.tick();
      expect(engine.deviceTrash.items(), hasLength(1), reason: 'not before');
      now = start.add(const Duration(days: 7, seconds: 1));
      await engine.tick();
      expect(engine.deviceTrash.items(), isEmpty);
      expect(staged(), isNot(contains(name)));
      expect(
        engine.artifacts.records.where((r) => r.path == copy.path),
        isEmpty,
      );
    });

    test('purge follows the trash_days the server advertises', () async {
      await trashed('three.txt');
      final start = now;
      cloud.trashDays = 3;
      await engine.trashListing();
      expect(engine.deviceTrash.days, 3);
      now = start.add(const Duration(days: 3));
      await engine.tick();
      expect(engine.deviceTrash.items(), hasLength(1));
      now = start.add(const Duration(days: 3, seconds: 1));
      await engine.tick();
      expect(engine.deviceTrash.items(), isEmpty);
    });

    test(
      'Restore puts a device copy back byte-identical, as "(restored)" '
      'when the path is taken; Delete now and Empty free the space',
      () async {
        final first = await trashed('copy.txt');
        final restored = await engine.trashRestore(deviceId: first.id);
        expect(restored, {'path': first.path, 'renamed': false});
        expect(local(first.path).readAsStringSync(), 'copy of copy.txt');
        expect(engine.deviceTrash.items(), isEmpty);
        await engine.tick();
        await engine.tick();
        expect(cloud.files[first.path], 'copy of copy.txt'.codeUnits);
        // Taken: deleted again (unproven), then a new file at the path.
        forgetHash(first.path);
        delete([first.path]);
        await engine.tick();
        local(first.path).writeAsStringSync('newer', flush: true);
        final second = engine.deviceTrash.items().single;
        final again = await engine.trashRestore(deviceId: second.id);
        expect(again['path'], '$dir/copy (restored).txt');
        expect(local(first.path).readAsStringSync(), 'newer');
        expect(
          local('$dir/copy (restored).txt').readAsStringSync(),
          'copy of copy.txt',
        );
        // Delete now and Empty.
        final a = await trashed('a.txt');
        await trashed('b.txt');
        await trashed('c.txt');
        expect(engine.deviceTrash.bytes, greaterThan(0));
        final deleted = await engine.trashDelete(const [], [a.id]);
        expect(deleted['deleted'], 1);
        expect(engine.deviceTrash.items(), hasLength(2));
        final emptied = await engine.trashEmpty();
        expect(emptied['deleted'], greaterThanOrEqualTo(2));
        expect(engine.deviceTrash.items(), isEmpty);
        expect(engine.deviceTrash.bytes, 0);
        expect(staged().where((n) => n.startsWith('preserved-')), isEmpty);
      },
    );

    test(
      'offline: device copies still show and restore, with a note',
      () async {
        final copy = await trashed('away.txt');
        cloud.online = false;
        final listing = await engine.trashListing();
        expect(
          listing['note'],
          "Can't reach the server: showing only this device's trash",
        );
        final entry = (listing['entries'] as List).single as Map;
        expect((entry['deviceId'], entry['onlyDevice']), (copy.id, true));
        await engine.trashRestore(deviceId: copy.id);
        expect(local(copy.path).readAsStringSync(), 'copy of away.txt');
      },
    );

    test(
      'migration: earlier deletion rows move into the device trash on the '
      'first pass (their clock starts then); conflict copies keep their rows',
      () async {
        SyncEngine.debugDeletionRecoveryRows = true;
        addTearDown(() => SyncEngine.debugDeletionRecoveryRows = false);
        // An earlier version's rows: a deletion copy and a never-uploaded file
        // removed locally, both Recovery rows.
        final deleted = await uploaded('old-delete.txt', 'old deletion');
        forgetHash(deleted);
        delete([deleted]);
        await engine.tick();
        const unsynced = '$dir/never-uploaded.txt';
        local(unsynced).writeAsStringSync('never uploaded', flush: true);
        cloud.uploadError = const CloudFailure('Write failed');
        await engine.tick();
        local(unsynced).deleteSync();
        await engine.tick();
        cloud.uploadError = null;
        // A replacement: another device's version replaced this one; the local
        // version is a recovery copy of a live row (not a deletion).
        final replaced = await uploaded('replaced.txt', 'local version');
        cloud.put(replaced, 'remote version');
        await engine.tick();
        for (final path in [deleted, unsynced, replaced]) {
          expect(engine.recovery.describe(path), isNotNull, reason: path);
          expect(await visible(path), isTrue, reason: path);
        }
        // The update.
        SyncEngine.debugDeletionRecoveryRows = false;
        now = now.add(const Duration(days: 30));
        await engine.tick();
        for (final path in [deleted, unsynced]) {
          expect(await visible(path), isFalse, reason: path);
          expect(engine.recovery.describe(path), isNull, reason: path);
        }
        final items = engine.deviceTrash.items();
        expect({for (final c in items) c.path}, {deleted, unsynced});
        expect(items.every((c) => c.at == now.millisecondsSinceEpoch), isTrue);
        expect(engine.recovery.describe(replaced), isNotNull);
        expect(await visible(replaced), isTrue);
        expect(ops('retained').where((o) => o.path == replaced), hasLength(1));
      },
    );
  });

  test('one entry per deletion: a device copy joins the server item of the '
      'same path and deletion; others stand alone, newest first', () {
    ServerTrashItem server(String id, String path, int deleted) =>
        ServerTrashItem(
          id: id,
          path: path,
          folder: false,
          size: 1,
          deleted: deleted,
          expires: deleted + 7 * 86400,
        );
    const t = 1800000000;
    final merged = mergeTrash(
      [
        server('1', 'a.txt', t),
        server('2', 'a.txt', t - 86400),
        server('3', 'b.txt', t),
      ],
      [
        const DeviceTrashItem(
          id: 'x',
          path: 'a.txt',
          size: 1,
          at: t * 1000 + 5000,
        ),
        const DeviceTrashItem(
          id: 'y',
          path: 'c.txt',
          size: 1,
          at: t * 1000 - 1000,
        ),
      ],
    );
    expect(
      [for (final e in merged) (e.server?.id, e.device?.id)],
      [('1', 'x'), ('3', null), (null, 'y'), ('2', null)],
    );
  });
}
