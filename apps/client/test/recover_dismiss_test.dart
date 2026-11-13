import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/ui/recovery_actions.dart';
import 'package:anj_cloud/core/sync/recovery_copies.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';
import 'test_platform.dart';

/// Counts every request, so "no network" is observable.
class _Cloud extends FakeCloud {
  int requests = 0;
  @override
  void check() {
    requests++;
    super.check();
  }
}

/// Spec #25 (decision #57): Recover and Dismiss of retained recovery copies.
void main() {
  // The release rules and the Recover/Dismiss primitives as such; the
  // device trash that now takes deletion copies (spec #44) is covered by
  // device_trash_test.dart.
  setUpAll(() => SyncEngine.debugDeletionRecoveryRows = true);
  tearDownAll(() => SyncEngine.debugDeletionRecoveryRows = false);
  // Deletions under Documents here are not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _Cloud cloud;
  late SyncEngine engine;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-recover-dismiss-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'recover', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _Cloud();
    engine = SyncEngine(store, tree, cloud);
    tree.ensureDirectory('Documents');
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  void restart() {
    final rootPath = tree.root.path;
    final stagePath = tree.staging.path;
    engine.close();
    tree = RootTree(Directory(rootPath), Directory(stagePath), NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    engine = SyncEngine(store, tree, cloud);
  }

  File local(String path) => File('${tree.root.path}/$path');
  Future<Map<String, dynamic>> row(String path) async =>
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(await projectEntry(engine, store.entries[path]!)))
            as Map,
      );
  List<String> staged() =>
      tree.staging.listSync().map((f) => p.basename(f.path)).toList()..sort();
  int stagedBytes() => tree.staging.listSync().whereType<File>().fold(
    0,
    (sum, f) => sum + f.lengthSync(),
  );
  Iterable<Operation> retained(String path) => store.operations.values.where(
    (o) => o.kind == 'retained' && o.path == path,
  );
  Map<String, Object?> dismiss(String path) => engine.applyBulk('dismiss', [
    {
      'path': path,
      'kind': 'file',
      'copies': engine.recovery.describe(path)!['paths'],
    },
  ]);
  Map<String, Object?> recover(String path) => engine.applyBulk('recover', [
    {'path': path, 'kind': 'file'},
  ]);

  /// No staging file without an ownership record; no reference to a copy
  /// whose file is gone; no Recover or Dismiss intent left behind.
  void expectConsistent() {
    final recorded = {
      for (final r in engine.artifacts.records) r.data['name'] as String,
    };
    expect(staged().where((n) => !recorded.contains(n)), isEmpty);
    for (final op in store.operations.values.where(
      (o) => o.kind == 'retained',
    )) {
      expect(File(op.staged!).existsSync(), isTrue, reason: op.staged);
    }
    for (final entry in store.entries.values) {
      for (final copy in entry.preservedCopies) {
        expect(File(copy).existsSync(), isTrue, reason: copy);
      }
    }
    expect(
      store.operations.values.where(
        (o) => o.kind == 'recover' || o.data['dismissing'] == true,
      ),
      isEmpty,
    );
  }

  // ------------------------------------------------------------ producers

  /// Upload recovery (SC-028): removed before it ever synced.
  Future<String> unsyncedRemoval([String text = 'local only bytes']) async {
    const path = 'Documents/probe.bin';
    local(path).writeAsStringSync(text, flush: true);
    cloud.uploadError = const CloudFailure('Write failed');
    await engine.tick();
    local(path).deleteSync();
    await engine.tick();
    cloud.uploadError = null;
    expect(store.entries[path]!.status, 'removed locally');
    return path;
  }

  Future<String> synced(String path, String text) async {
    local(path).writeAsStringSync(text, flush: true);
    await engine.tick();
    expect(cloud.files.containsKey(path), isTrue);
    return path;
  }

  /// Deletion: Delete everywhere, then a late editor write to the
  /// preserved copy (decision #37: retained, the row a Recovery copy).
  Future<String> deletion() async {
    final path = await synced('Documents/deleted.txt', 'original');
    final held = local(path).openSync(mode: FileMode.append);
    try {
      engine.requestDelete(path);
      await engine.tick();
      held.writeStringSync(' late editor write');
      held.flushSync();
      await engine.tick();
    } finally {
      held.closeSync();
    }
    expect(store.entries[path]!.status, 'deleted');
    expect(store.entries[path]!.conflict, preservedChangedConflict);
    return path;
  }

  /// Replacement: another device's version replaced a local file; the
  /// local version is preserved and never provably redundant.
  Future<String> replacement() async {
    final path = await synced('Documents/replaced.txt', 'local version');
    cloud.put(path, 'remote version');
    await engine.tick();
    expect(local(path).readAsStringSync(), 'remote version');
    return path;
  }

  /// Eviction quarantine kept beside a replacement root file.
  Future<String> quarantine() async {
    // Documents itself is never Cloud-only (spec #34 P7).
    const path = 'Documents/Evicted/evicted.txt';
    tree.ensureDirectory('Documents/Evicted');
    await synced(path, 'quarantined bytes');
    engine.setRetention('Documents/Evicted', Retention.cloud);
    engine.evictions.barrier = (point, op, fd) {
      if (point == 'quarantined') throw StateError('simulated crash');
    };
    try {
      await engine.tick();
    } on StateError {
      // The crash left the bytes quarantined in staging.
    }
    engine.evictions.barrier = null;
    restart();
    local(path).writeAsStringSync('replacement', flush: true);
    engine.setRetention('Documents/Evicted', Retention.local);
    await engine.tick();
    expect(store.entries[path]!.conflict, replacementRetainedConflict);
    return path;
  }

  /// Edited conflict copy: Keep both of a late preserved edit.
  Future<String> conflictCopy() async {
    final path = await synced('Documents/note.txt', 'original');
    final held = local(path).openSync(mode: FileMode.append);
    try {
      cloud.put(path, 'remote replacement');
      await engine.tick();
      held.writeStringSync(' late edit');
      held.flushSync();
      await engine.tick();
      await engine.keepBoth(path);
      await engine.tick();
    } finally {
      held.closeSync();
    }
    return store.entries.keys.singleWhere((k) => k.contains('.conflict-'));
  }

  group('producers: Recover and Dismiss appear exactly on recovery rows', () {
    test('upload recovery (removed before it synced)', () async {
      final path = await unsyncedRemoval();
      final r = await row(path);
      expect(fileBadge(r), 'Recovery copy');
      expect(hasRecoveryCopies(r), isTrue);
      expect(canRecover(r), isTrue);
      expect(recoveryBytes(r), 'local only bytes'.length);
    });
    test('deletion (preserved copy, late write)', () async {
      final path = await deletion();
      final r = await row(path);
      expect(fileBadge(r), 'Recovery copy');
      expect(hasRecoveryCopies(r), isTrue);
    });
    test('replacement (preserved local version)', () async {
      final path = await replacement();
      final r = await row(path);
      expect(hasRecoveryCopies(r), isTrue);
      expect(recoveryBytes(r), 'local version'.length);
    });
    test('eviction quarantine kept beside a replacement', () async {
      final path = await quarantine();
      final r = await row(path);
      expect(hasRecoveryCopies(r), isTrue);
      expect(canRecover(r), isTrue);
    });
    test('Keep both: the live conflict copy is never a recovery copy, '
        'decided by identity (same inode), not by name', () async {
      final path = await conflictCopy();
      if (!tree.native.hardLinks) {
        // Android renames the copy into place: no staging name remains, so
        // there is nothing to classify and no bytes beyond the live file.
        expect(
          engine.artifacts.records.where(
            (o) => o.data['role'] == 'conflict-edited-copy',
          ),
          isEmpty,
        );
        final r = await row(path);
        expect(fileBadge(r), 'Local');
        expect(hasRecoveryCopies(r), isFalse);
        return;
      }
      final record = engine.artifacts.records.singleWhere(
        (o) => o.data['role'] == 'conflict-edited-copy',
      );
      final copy = File(record.staged!).statSync();
      final live = local(path).statSync();
      // The staging name is a hard link to the live, synced file.
      expect(
        engine.artifacts.native
            .info(tree.stageFd, p.basename(record.staged!))
            .links,
        2,
      );
      expect(copy.modified, live.modified);
      expect(cloud.files.containsKey(path), isTrue);
      final r = await row(path);
      expect(fileBadge(r), 'Local');
      expect(hasRecoveryCopies(r), isFalse);
      expect(r['recoveryCopies'], isNull);
      // The original row lists only its genuinely separate preserved copy.
      final original = engine.recovery.describe('Documents/note.txt');
      expect(
        (original?['paths'] as List? ?? []).where(
          (s) => (s as String).contains('conflict-'),
        ),
        isEmpty,
      );
    });
    test(
      'Keep both, then the conflict copy deleted in the file manager: '
      'the leftover copy offers Recover and Dismiss, and Dismiss frees it',
      () async {
        final path = await conflictCopy();
        expect(hasRecoveryCopies(await row(path)), isFalse);
        if (!tree.native.hardLinks) {
          // Android kept no staging copy of the installed file (it was
          // renamed into place), so a deletion leaves nothing to recover
          // locally and frees no staging bytes.
          final before = stagedBytes();
          local(path).deleteSync();
          await engine.tick();
          await engine.tick();
          expect(store.entries[path]!.status, startsWith('deleted'));
          expect(hasRecoveryCopies(await row(path)), isFalse);
          expect(stagedBytes(), before);
          expectConsistent();
          return;
        }
        final record = engine.artifacts.records.singleWhere(
          (o) => o.data['role'] == 'conflict-edited-copy',
        );
        final bytes = File(record.staged!).lengthSync();
        local(path).deleteSync();
        await engine.tick();
        await engine.tick();
        expect(store.entries[path]!.status, startsWith('deleted'));
        final r = await row(path);
        expect(visibleInLibrary(r), isTrue);
        expect(hasRecoveryCopies(r), isTrue);
        expect(canRecover(r), isTrue);
        expect(recoveryBytes(r), bytes);
        final before = stagedBytes();
        expect(dismiss(path)['accepted'], 1);
        expect(before - stagedBytes(), bytes);
        expect(File(record.staged!).existsSync(), isFalse);
        expect(visibleInLibrary(await row(path)), isFalse);
        expectConsistent();
      },
    );

    test(
      'Keep both whose copy never syncs (upload refused): the live copy '
      'is no recovery copy, with or without hard links (PR #60 F3)',
      () async {
        final path = await synced('Documents/note.txt', 'original');
        final held = local(path).openSync(mode: FileMode.append);
        String copy;
        try {
          cloud.put(path, 'remote replacement');
          await engine.tick();
          held.writeStringSync(' late edit');
          held.flushSync();
          await engine.tick();
          cloud.uploadLimit = 4;
          await engine.keepBoth(path);
          await engine.tick();
          await engine.tick();
        } finally {
          held.closeSync();
        }
        copy = store.entries.keys.singleWhere((k) => k.contains('.conflict-'));
        expect(cloud.files.containsKey(copy), isFalse, reason: 'refused');
        expect(local(copy).existsSync(), isTrue);
        final r = await row(copy);
        expect(hasRecoveryCopies(r), isFalse);
        expect(r['recoveryCopies'], isNull);
      },
    );

    test('never on ordinary rows', () async {
      await synced('Documents/plain.txt', 'plain');
      await synced('Documents/cloud.txt', 'cloud');
      await unsyncedRemoval();
      expect(hasRecoveryCopies(await row('Documents/plain.txt')), isFalse);
      expect((await row('Documents/plain.txt'))['recoveryCopies'], isNull);
      expect(hasRecoveryCopies(await row('Documents')), isFalse);
    });
  });

  group('Recover', () {
    test('free path: restored, verified, copy released, then syncs', () async {
      final path = await unsyncedRemoval('come back');
      final result = recover(path);
      expect(result['accepted'], 1);
      expect((result['restored'] as List).single, {
        'path': path,
        'destination': path,
        'kept': false,
      });
      expect(local(path).readAsStringSync(), 'come back');
      expect(retained(path), isEmpty);
      expect(staged(), isEmpty);
      expectConsistent();
      await engine.tick();
      expect(String.fromCharCodes(cloud.files[path]!), 'come back');
      final r = await row(path);
      expect(hasRecoveryCopies(r), isFalse);
      expect(fileBadge(r), 'Local');
    });

    test('occupied path: "(recovered)", then "(recovered 2)"; nothing '
        'overwritten', () async {
      final path = await replacement();
      local('Documents/replaced (recovered).txt').writeAsStringSync('mine');
      final result = recover(path);
      expect(
        ((result['restored'] as List).single as Map)['destination'],
        'Documents/replaced (recovered 2).txt',
      );
      expect(local(path).readAsStringSync(), 'remote version');
      expect(
        local('Documents/replaced (recovered).txt').readAsStringSync(),
        'mine',
      );
      expect(
        local('Documents/replaced (recovered 2).txt').readAsStringSync(),
        'local version',
      );
      expect(retained(path), isEmpty);
      expectConsistent();
    });

    test('a cloud-only file at the path counts as occupied', () async {
      const path = 'Documents/probe.bin';
      await unsyncedRemoval();
      // Another device created the same name; the cloud has it, this
      // device does not (yet).
      store.entries[path]!
        ..etag = '"remote"'
        ..status = 'cloud-only';
      store.save();
      expect(
        engine.recovery.destination(path),
        'Documents/probe (recovered).bin',
      );
      expect(
        engine.recovery.destination('Documents/archive'),
        'Documents/archive',
      );
    });

    test('a file that appears at the destination before the rename is '
        'never replaced', () async {
      final path = await unsyncedRemoval('ours');
      engine.recovery.barrier = (point, op) {
        if (point == 'recover-before-rename') {
          local(path).writeAsStringSync('appeared meanwhile');
        }
      };
      final result = recover(path);
      expect(result['accepted'], 0);
      expect((result['errors'] as List).single, contains('kept'));
      expect(local(path).readAsStringSync(), 'appeared meanwhile');
      expect(File(retained(path).single.staged!).readAsStringSync(), 'ours');
      expectConsistent();
    });

    test('full disk: the copy is kept, nothing reaches the folder, an error '
        'is shown', () async {
      final path = await unsyncedRemoval('precious');
      final before = staged();
      engine.recovery.copy = (name, target) {
        target.writeAsStringSync('prec');
        throw FileSystemException(
          'Write failed',
          target.path,
          const OSError('No space left on device', 28),
        );
      };
      final result = recover(path);
      expect(result['accepted'], 0);
      final error = (result['errors'] as List).single as String;
      expect(error, contains('Not enough disk space'));
      expect(error, contains('The recovery copy is kept.'));
      expect(local(path).existsSync(), isFalse);
      expect(staged(), before);
      expect(
        File(retained(path).single.staged!).readAsStringSync(),
        'precious',
      );
      expectConsistent();
      expect(hasRecoveryCopies(await row(path)), isTrue);
    });

    test('crash between write and rename: no half-written file, copy '
        'kept and listed', () async {
      final path = await unsyncedRemoval('survives');
      engine.recovery.barrier = (point, op) {
        if (point == 'recover-before-rename') throw StateError('crash');
      };
      expect(() => recover(path), throwsStateError);
      expect(
        staged().where((n) => n.startsWith('recover-temp-')),
        hasLength(1),
      );
      restart();
      await engine.tick();
      expect(local(path).existsSync(), isFalse);
      expect(staged().where((n) => n.startsWith('recover-temp-')), isEmpty);
      expect(
        File(retained(path).single.staged!).readAsStringSync(),
        'survives',
      );
      expect(hasRecoveryCopies(await row(path)), isTrue);
      expectConsistent();
    });

    test('crash after the rename: the restored file is verified and the '
        'copy released on restart', () async {
      final path = await unsyncedRemoval('restored');
      engine.recovery.barrier = (point, op) {
        if (point == 'recover-after-rename-before-db') {
          throw StateError('crash');
        }
      };
      expect(() => recover(path), throwsStateError);
      restart();
      expect(
        store.operations.values.where((o) => o.kind == 'recover'),
        hasLength(1),
      );
      engine.recovery.recoverInterrupted();
      expect(local(path).readAsStringSync(), 'restored');
      expect(retained(path), isEmpty);
      expect(staged(), isEmpty);
      expectConsistent();
    });

    test(
      'a restored file changed before verification keeps the copy',
      () async {
        final path = await unsyncedRemoval('original bytes');
        engine.recovery.barrier = (point, op) {
          if (point == 'recover-after-rename-before-db') {
            local(path).writeAsStringSync('edited at once');
          }
        };
        final result = recover(path);
        expect(((result['restored'] as List).single as Map)['kept'], isTrue);
        expect(
          File(retained(path).single.staged!).readAsStringSync(),
          'original bytes',
        );
        expectConsistent();
      },
    );

    Future<String> inDeletedFolder({required bool remotely}) async {
      tree.ensureDirectory('Documents/proj');
      await engine.tick();
      const path = 'Documents/proj/probe.bin';
      local(path).writeAsStringSync('only here', flush: true);
      cloud.uploadError = const CloudFailure('Write failed');
      await engine.tick();
      // Removed before it synced: a recovery copy.
      local(path).deleteSync();
      await engine.tick();
      cloud.uploadError = null;
      if (remotely) {
        cloud.directories.remove('Documents/proj');
        cloud.versions.remove('Documents/proj');
      } else {
        Directory('${tree.root.path}/Documents/proj').deleteSync();
      }
      await engine.tick();
      await engine.tick();
      expect(hasRecoveryCopies(await row(path)), isTrue);
      expect(engine.recovery.parentExists(path), isFalse);
      return path;
    }

    for (final remotely in [false, true]) {
      test('a deleted folder (${remotely ? 'remotely' : 'locally'}) is never '
          'recreated: restored to the top level, then uploads', () async {
        final path = await inDeletedFolder(remotely: remotely);
        final result = recover(path);
        expect((result['restored'] as List).single, {
          'path': path,
          'destination': 'probe.bin',
          'kept': false,
        });
        expect(
          Directory('${tree.root.path}/Documents/proj').existsSync(),
          isFalse,
        );
        expect(local('probe.bin').readAsStringSync(), 'only here');
        expectConsistent();
        for (var i = 0; i < 3; i++) {
          await engine.tick();
        }
        expect(String.fromCharCodes(cloud.files['probe.bin']!), 'only here');
        // Nothing recreated it in the cloud either. (A local folder
        // deletion awaits the server's folder proof, as before.)
        if (remotely) {
          expect(cloud.directories.contains('Documents/proj'), isFalse);
        }
        expect(store.entries['probe.bin']!.status, 'current local');
        expect(store.entries['probe.bin']!.conflict, isNull);
        expect(
          Directory('${tree.root.path}/Documents/proj').existsSync(),
          isFalse,
        );
        expect(
          recoverMessage(Map<String, dynamic>.from(result), paused: false),
          'Restored to probe.bin. Its folder Documents/proj no longer exists. '
          'It syncs normally.',
        );
      });
    }

    test('a folder whose deletion is still pending counts as gone', () async {
      tree.ensureDirectory('Documents/proj');
      await synced('Documents/proj/keep.txt', 'synced');
      const path = 'Documents/proj/probe.bin';
      local(path).writeAsStringSync('only here', flush: true);
      cloud.uploadError = const CloudFailure('Write failed');
      await engine.tick();
      local(path).deleteSync();
      await engine.tick();
      cloud.uploadError = null;
      expect(hasRecoveryCopies(await row(path)), isTrue);
      engine.requestDelete('Documents/proj');
      expect(
        Directory('${tree.root.path}/Documents/proj').existsSync(),
        isTrue,
      );
      expect(engine.recovery.parentExists(path), isFalse);
      final result = recover(path);
      expect(
        ((result['restored'] as List).single as Map)['destination'],
        'probe.bin',
      );
      expect(local(path).existsSync(), isFalse);
      expect(local('probe.bin').readAsStringSync(), 'only here');
      expectConsistent();
    });

    test('top level occupied too: "(recovered)" at the top level', () async {
      final path = await inDeletedFolder(remotely: false);
      local('probe.bin').writeAsStringSync('someone else');
      final result = recover(path);
      expect(
        ((result['restored'] as List).single as Map)['destination'],
        'probe (recovered).bin',
      );
      expect(local('probe.bin').readAsStringSync(), 'someone else');
    });

    test('a failed fsync after the rename: reported restored, copy kept '
        'until durability is confirmed', () async {
      final path = await unsyncedRemoval('in place');
      final real = engine.recovery.rename;
      engine.recovery.rename = (destination, name) {
        real(destination, name);
        throw const FileSystemException(
          'fsync failed',
          '',
          OSError('Input/output error', 5),
        );
      };
      final result = recover(path);
      expect(result['accepted'], 1);
      final restored = (result['restored'] as List).single as Map;
      expect(restored['unconfirmed'], isTrue);
      expect(restored['kept'], isTrue);
      expect(local(path).readAsStringSync(), 'in place');
      expect(
        File(retained(path).single.staged!).readAsStringSync(),
        'in place',
      );
      expect(
        recoverMessage(Map<String, dynamic>.from(result), paused: false),
        contains('did not confirm'),
      );
      expectConsistent();
    });

    test('newest copy first; older copies stay listed', () async {
      final path = await replacement();
      // A second remote replacement preserves the next local version.
      cloud.put(path, 'remote version 2');
      await engine.tick();
      expect(retained(path), hasLength(2));
      final copies = retained(path).map((o) => File(o.staged!)).toList();
      copies[0].setLastModifiedSync(DateTime(2026, 1, 1));
      copies[1].setLastModifiedSync(DateTime(2026, 6, 1));
      final newest = copies[1].readAsStringSync();
      final result = recover(path);
      final destination =
          ((result['restored'] as List).single as Map)['destination'] as String;
      expect(local(destination).readAsStringSync(), newest);
      expect(retained(path), hasLength(1));
      expect(hasRecoveryCopies(await row(path)), isTrue);
      expectConsistent();
    });
  });

  group('Dismiss', () {
    test(
      'confirm deletes all of the row\'s copies; the row disappears',
      () async {
        final path = await deletion();
        expect(dismiss(path)['accepted'], 1);
        expect(retained(path), isEmpty);
        expect(store.entries[path]!.preservedCopies, isEmpty);
        expect(store.entries[path]!.conflict, isNull);
        final r = await row(path);
        expect(visibleInLibrary(r), isFalse);
        expect(staged(), isEmpty);
        expectConsistent();
        await engine.tick();
        expect(visibleInLibrary(await row(path)), isFalse);
        expect(cloud.files.containsKey(path), isFalse);
      },
    );

    test('a row whose file still exists returns to normal', () async {
      final path = await quarantine();
      expect(dismiss(path)['accepted'], 1);
      expect(store.entries[path]!.conflict, isNull);
      expect(local(path).readAsStringSync(), 'replacement');
      await engine.tick();
      await engine.tick();
      final r = await row(path);
      expect(hasConflict(r), isFalse);
      expect(hasRecoveryCopies(r), isFalse);
      expect(needsAttention(r), isFalse);
      expect(String.fromCharCodes(cloud.files[path]!), 'replacement');
      expectConsistent();
    });

    test(
      'only the confirmed copies: one that appeared since is kept',
      () async {
        final path = await replacement();
        final confirmed = engine.recovery.describe(path)!['paths'];
        cloud.put(path, 'remote version 2');
        await engine.tick();
        expect(retained(path), hasLength(2));
        engine.applyBulk('dismiss', [
          {'path': path, 'kind': 'file', 'copies': confirmed},
        ]);
        expect(retained(path), hasLength(1));
        expect(hasRecoveryCopies(await row(path)), isTrue);
        expectConsistent();
      },
    );

    test('a stale confirmation deletes nothing', () async {
      final path = await unsyncedRemoval();
      final result = engine.applyBulk('dismiss', [
        {
          'path': path,
          'kind': 'file',
          'copies': ['/elsewhere/copy'],
        },
      ]);
      expect(result['accepted'], 0);
      expect(retained(path), hasLength(1));
    });

    test(
      'never on a row without copies; others in the batch still go',
      () async {
        final plain = await synced('Documents/plain.txt', 'plain');
        final path = await unsyncedRemoval();
        final result = engine.applyBulk('dismiss', [
          {'path': plain, 'kind': 'file', 'copies': <String>[]},
          {
            'path': path,
            'kind': 'file',
            'copies': engine.recovery.describe(path)!['paths'],
          },
        ]);
        expect(result['accepted'], 1);
        expect(result['failed'], 1);
        expect(local(plain).readAsStringSync(), 'plain');
        expect(retained(path), isEmpty);
      },
    );

    test('a copy another row also lists: only this row\'s reference goes; '
        'the bytes go with the last reference', () async {
      final a = await unsyncedRemoval('shared bytes');
      const b = 'Documents/other.bin';
      local(b).writeAsStringSync('b', flush: true);
      cloud.uploadError = const CloudFailure('Write failed');
      await engine.tick();
      local(b).deleteSync();
      await engine.tick();
      cloud.uploadError = null;
      final shared = retained(a).single.staged!;
      store.entries[b]!.preservedCopies.add(shared);
      store.save();
      expect(dismiss(a)['accepted'], 1);
      expect(File(shared).readAsStringSync(), 'shared bytes');
      expect(retained(a), isEmpty);
      expect(store.entries[b]!.preservedCopies, contains(shared));
      expect((engine.recovery.describe(b)!['paths'] as List), contains(shared));
      expect(dismiss(b)['accepted'], 1);
      expect(File(shared).existsSync(), isFalse);
      expect(engine.recovery.describe(b), isNull);
      expectConsistent();
    });

    test('a copy referenced by an active operation is never offered', () async {
      final path = await unsyncedRemoval();
      final staged = retained(path).single.staged!;
      store.operations['busy'] = Operation(
        'busy',
        'working',
        'Documents/elsewhere.txt',
        staged: staged,
      );
      store.save();
      expect(engine.recovery.describe(path), isNull);
      store.operations.remove('busy');
      store.save();
    });

    test('a reference outside staging is never deleted or dropped', () async {
      final path = await replacement();
      final outside = File('${fixture.path}/outside-copy')
        ..writeAsStringSync('not ours');
      store.entries[path]!.preservedCopies.add(outside.path);
      store.save();
      final result = dismiss(path);
      expect((result['errors'] as List).single, contains('outside'));
      expect(outside.readAsStringSync(), 'not ours');
      expect(store.entries[path]!.preservedCopies, contains(outside.path));
    });

    test('a dangling reference (copy already gone) is cleared', () async {
      final path = await unsyncedRemoval();
      final copy = retained(path).single;
      File(copy.staged!).deleteSync();
      expect(dismiss(path)['accepted'], 1);
      expect(retained(path), isEmpty);
      expect(visibleInLibrary(await row(path)), isFalse);
      expectConsistent();
    });

    test('a copy open in another program is kept and reported', () async {
      final path = await unsyncedRemoval();
      final held = File(retained(path).single.staged!).openSync();
      try {
        final result = dismiss(path);
        expect(result['accepted'], 0);
        expect((result['errors'] as List).single, contains('kept'));
        expect(retained(path), hasLength(1));
        expectConsistent();
      } finally {
        held.closeSync();
      }
    });

    for (final point in [
      'dismiss-before-unlink',
      'dismiss-after-unlink-before-db',
    ]) {
      test('crash at $point: the copy or nothing, never a dangling '
          'reference', () async {
        final path = await unsyncedRemoval();
        final copy = engine.recovery.describe(path)!;
        engine.recovery.barrier = (at, record) {
          if (at == point) throw StateError('crash');
        };
        expect(() => dismiss(path), throwsStateError);
        restart();
        await engine.tick();
        expectConsistent();
        if (point == 'dismiss-before-unlink') {
          expect(engine.recovery.describe(path), copy);
          expect(fileBadge(await row(path)), 'Recovery copy');
        } else {
          expect(engine.recovery.describe(path), isNull);
          expect(visibleInLibrary(await row(path)), isFalse);
          expect(staged(), isEmpty);
        }
      });
    }
  });

  group(
    'one file under several staging names (hard links)',
    () {
      /// Keep both, then Delete everywhere on the conflict copy: the deleted
      /// file's preserved name and its Keep-both name share one inode.
      Future<String> twoNames() async {
        final path = await conflictCopy();
        engine.requestDelete(path);
        await engine.tick();
        await engine.tick();
        expect(store.entries[path]!.status, startsWith('deleted'));
        final copies = engine.recovery.describe(path)!;
        expect(copies['paths'] as List, hasLength(2));
        expect(copies['count'], 1);
        return path;
      }

      /// A third owned name for the same file, as installOwned would leave.
      Future<String> addName(String path) async {
        final first =
            (engine.recovery.describe(path)!['paths'] as List).first as String;
        final name = 'download-${uniqueId()}';
        final link = await Process.run('ln', [
          first,
          '${tree.staging.path}/$name',
        ]);
        expect(link.exitCode, 0, reason: '${link.stderr}');
        final info = engine.artifacts.native.info(tree.stageFd, name);
        final record =
            Operation(
                uniqueId(),
                'artifact',
                path,
                staged: '${tree.staging.path}/$name',
                phase: 'complete',
              )
              ..data = {
                'role': 'download',
                'name': name,
                'directoryIdentity': tree.native.identity(tree.stageFd),
                'identity': info.identity,
                'stamp': info.stamp,
              };
        store.operations[record.id] = record;
        store.save();
        return name;
      }

      test('Dismiss deletes every name on the first try', () async {
        final path = await twoNames();
        final names = engine.recovery.describe(path)!['paths'] as List;
        final result = dismiss(path);
        expect(result['accepted'], 1, reason: '${result['errors']}');
        for (final name in names) {
          expect(File(name as String).existsSync(), isFalse);
        }
        expect(engine.recovery.describe(path), isNull);
        expect(visibleInLibrary(await row(path)), isFalse);
        expectConsistent();
      });

      test('Recover verifies once and releases every name', () async {
        final path = await twoNames();
        final names = engine.recovery.describe(path)!['paths'] as List;
        final bytes = File(names.first as String).readAsStringSync();
        final result = recover(path);
        final restored = (result['restored'] as List).single as Map;
        expect(restored['kept'], isFalse, reason: '$result');
        expect(
          local(restored['destination'] as String).readAsStringSync(),
          bytes,
        );
        for (final name in names) {
          expect(File(name as String).existsSync(), isFalse);
        }
        expect(engine.recovery.describe(path), isNull);
        expectConsistent();
      });

      test('three names: Dismiss deletes all of them at once', () async {
        final path = await twoNames();
        await addName(path);
        final copies = engine.recovery.describe(path)!;
        expect(copies['paths'] as List, hasLength(3));
        expect(copies['count'], 1);
        final before = stagedBytes();
        final size = copies['bytes'] as int;
        final names = copies['paths'] as List;
        final result = dismiss(path);
        expect(result['accepted'], 1, reason: '${result['errors']}');
        expect(engine.recovery.describe(path), isNull);
        for (final name in names) {
          expect(File(name as String).existsSync(), isFalse);
        }
        // stagedBytes counts each name; all three are gone.
        expect(before - stagedBytes(), 3 * size);
        expectConsistent();
      });

      test('three names: Recover releases all of them', () async {
        final path = await twoNames();
        await addName(path);
        final names = engine.recovery.describe(path)!['paths'] as List;
        final result = recover(path);
        expect(((result['restored'] as List).single as Map)['kept'], isFalse);
        expect(engine.recovery.describe(path), isNull);
        for (final name in names) {
          expect(File(name as String).existsSync(), isFalse);
        }
        expectConsistent();
      });
    },
    // Several staging names for one file exist only where installs link
    // (Linux, macOS); Android renames installs (decision #123 (2)).
    skip: NativeRootFs().hardLinks ? false : 'installs do not link here',
  );

  test('bulk size counts a file shared by two rows once', () {
    Map<String, dynamic> e(String path, List<Map> files) => {
      'path': path,
      'recoveryCopies': {
        'paths': [for (final f in files) f['identity']],
        'files': files,
        'count': files.length,
        'bytes': files.fold<int>(0, (s, f) => s + (f['size'] as int)),
        'recoverable': true,
      },
    };
    final rows = [
      e('a', [
        {'identity': 'v:1', 'size': 100 * 1024 * 1024},
      ]),
      e('b', [
        {'identity': 'v:1', 'size': 100 * 1024 * 1024},
        {'identity': 'v:2', 'size': 50 * 1024 * 1024},
      ]),
    ];
    expect(recoveryTotalBytes(rows), 150 * 1024 * 1024);
    expect(dismissPrompt(rows), contains('(150 MB)'));
  });

  test('paused, with no network: both work locally; Recover uploads after '
      'Resume', () async {
    final path = await unsyncedRemoval('offline restore');
    // A second row to dismiss.
    const gone = 'Documents/gone.bin';
    local(gone).writeAsStringSync('dismiss me', flush: true);
    cloud.uploadError = const CloudFailure('Write failed');
    await engine.tick();
    local(gone).deleteSync();
    await engine.tick();
    cloud.uploadError = null;
    store.setSetting('paused', '1');
    cloud.online = false;
    final events = <Map>[];
    final input = StreamController<Object?>();
    final loop = WorkerLoop(
      engine,
      (event) => events.add(event as Map),
      interval: const Duration(milliseconds: 20),
      pausedInterval: const Duration(milliseconds: 20),
    );
    final done = loop.run(input.stream);
    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 500 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    final requests = cloud.requests;
    input.add({
      'action': 'bulk',
      'value': 'recover',
      'request': 'r1',
      'targets': [
        {'path': path, 'kind': 'file'},
      ],
    });
    input.add({
      'action': 'bulk',
      'value': 'dismiss',
      'request': 'd1',
      'targets': [
        {
          'path': gone,
          'kind': 'file',
          'copies': engine.recovery.describe(gone)!['paths'],
        },
      ],
    });
    Map result(String id) => events.lastWhere(
      (e) => e['event'] == 'bulkResult' && e['request'] == id,
    );
    await until(
      () => events.where((e) => e['event'] == 'bulkResult').length == 2,
    );
    expect(result('r1')['accepted'], 1, reason: '${result('r1')}');
    expect(result('d1')['accepted'], 1, reason: '${result('d1')}');
    expect(local(path).readAsStringSync(), 'offline restore');
    expect(engine.recovery.describe(gone), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cloud.requests, requests, reason: 'no network while paused');
    expect(cloud.files.containsKey(path), isFalse);
    cloud.online = true;
    input.add({'action': 'resume'});
    await until(() => cloud.files.containsKey(path));
    expect(String.fromCharCodes(cloud.files[path]!), 'offline restore');
    input.add({'action': 'stop'});
    await done;
    await input.close();
    engine = SyncEngine(
      Manifest(Directory('${fixture.path}/profile')),
      RootTree(tree.root, tree.staging, NativeRootFs()),
      cloud,
    );
  });

  test('Laptop: the persisted stuck probe becomes a Recovery copy; Dismiss '
      'clears it, frees its bytes and changes no other row', () async {
    const big = 'Documents/big.bin';
    const size = 3 * 1024 * 1024;
    final other = await synced('Documents/other.txt', 'unrelated');
    local(big).writeAsBytesSync(List.filled(size, 7), flush: true);
    cloud.uploadError = const CloudFailure('Write failed');
    await engine.tick();
    engine.close();
    local(big).deleteSync();
    // The state Laptop holds (as in the #30 reproduction): a failed upload's
    // intent and complete snapshot, the source rm'd, the row stuck.
    final earlier = Manifest(Directory('${fixture.path}/profile'));
    earlier.entries[big]!.status =
        'pending: SocketException: Broken pipe (OS Error: Broken pipe, '
        'errno = 32), address = 127.0.0.1, port = 47172';
    earlier.save();
    expect(
      earlier.operations.values
          .where((o) => o.kind == 'upload')
          .single
          .data['dispatchState'],
      'started',
    );
    earlier.close();
    store = Manifest(Directory('${fixture.path}/profile'));
    tree = RootTree(tree.root, tree.staging, NativeRootFs());
    engine = SyncEngine(store, tree, cloud);
    cloud.uploadError = null;
    await engine.tick();
    final r = await row(big);
    expect(fileBadge(r), 'Recovery copy');
    expect(hasRecoveryCopies(r), isTrue);
    expect(recoveryBytes(r), size);
    expect(dismissPrompt([r]), contains('(3 MB)'));
    String others() => jsonEncode({
      for (final e in store.entries.values)
        if (e.path != big) e.path: e.toJson(),
    });
    final before = others();
    final bytes = stagedBytes();
    expect(dismiss(big)['accepted'], 1);
    expect(bytes - stagedBytes(), size);
    expect(visibleInLibrary(await row(big)), isFalse);
    expectConsistent();
    expect(others(), before);
    await engine.tick();
    expect(others(), before);
    expect(local(other).readAsStringSync(), 'unrelated');
    expect(visibleInLibrary(await row(big)), isFalse);
  });

  for (final phase in [
    'recover-before-rename',
    'recover-after-rename-before-db',
    'dismiss-before-unlink',
    'dismiss-after-unlink-before-db',
  ]) {
    test('a real process crash at $phase converges', () async {
      final path = '${fixture.path}/crash-$phase';
      final dart = testDartExecutable;
      final crashed = await Process.run(dart, [
        'run',
        'tool/recover_dismiss_fixture.dart',
        path,
        phase,
      ]);
      expect(
        crashed.exitCode,
        86,
        reason: '${crashed.stdout}\n${crashed.stderr}',
      );
      final rootFile = File('$path/files/anj-cloud/Documents/probe.bin');
      // At the crash: a Recover never left a partial file in the folder.
      if (phase == 'recover-before-rename') {
        expect(rootFile.existsSync(), isFalse);
      }
      if (phase == 'recover-after-rename-before-db') {
        expect(rootFile.readAsStringSync(), 'only copy of these bytes');
      }
      final resumed = await Process.run(dart, [
        'run',
        'tool/recover_dismiss_fixture.dart',
        path,
        'resume',
      ]);
      expect(
        resumed.exitCode,
        0,
        reason: '${resumed.stdout}\n${resumed.stderr}',
      );
      final result =
          jsonDecode(File('$path/result.json').readAsStringSync()) as Map;
      expect(result['unrecorded'], isEmpty);
      expect(result['intents'], 0);
      expect((result['retained'] as List).every((v) => v == true), isTrue);
      switch (phase) {
        case 'recover-before-rename' || 'dismiss-before-unlink':
          // The copy, intact and listed; nothing in the folder.
          expect(result['root'], isNull);
          expect(result['retained'], [true]);
          expect((result['copies'] as Map)['count'], 1);
          expect(result['records'], ['upload']);
        case 'recover-after-rename-before-db':
          // Restored, verified, released; then synced normally.
          expect(result['root'], 'only copy of these bytes');
          expect(result['cloud'], 'only copy of these bytes');
          expect(result['retained'], isEmpty);
          expect(result['copies'], isNull);
        case 'dismiss-after-unlink-before-db':
          expect(result['root'], isNull);
          expect(result['retained'], isEmpty);
          expect(result['records'], isEmpty);
          expect(result['copies'], isNull);
          expect(result['status'], 'removed locally');
      }
    });
  }
}
