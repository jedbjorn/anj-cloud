import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/platform/native/eviction_native.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Sync-root identity across reboot. On btrfs every subvolume's st_dev is an
/// anonymous device number assigned when it is loaded, so it changes across
/// reboot while the inode and the statfs f_fsid stay. Fixtures live on tmpfs;
/// the native seam `debugVolume` shifts every reported st_dev (the reboot)
/// and makes tmpfs report a fixed stable fsid (btrfs/ext4). Without the fsid
/// seam tmpfs keeps the decimal st_dev: the pre-fix format, which is also how
/// the legacy profiles under migration were written.
void main() {
  // Deletions under Documents here are not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late Directory profile;
  late NativeRootFs native;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  const fsid = 0x2085a06437881631;
  const otherFsid = 0x1111222233334444;
  const settle = Duration(milliseconds: 2100);
  // Legacy Linux profiles: a root without a stable fsid (tmpfs here, the
  // pre-fix dev:ino identity) and btrfs renumbering st_dev at boot. An APFS
  // root always has a stable volume identity, so these have no macOS case.
  final legacyLinux = linuxOnly(
    'models a root without a stable fsid and btrfs device renumbering; an '
    'APFS root always has a stable volume identity',
  );

  RootTree trusted(RootTree value) {
    final vm = Directory('${fixture.path}/vm')..createSync(recursive: true);
    File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('3000\n');
    File('${vm.path}/dirty_writeback_centisecs').writeAsStringSync('1500\n');
    File('${vm.path}/laptop_mode').writeAsStringSync('0\n');
    return value
      ..debugFsMagic = 0xEF53
      ..vmDirectory = vm.path;
  }

  RootTree openTree() => trusted(
    RootTree(
      Directory('${fixture.path}/files/anj-cloud'),
      Directory('${fixture.path}/files/.anj-cloud-identity'),
      native,
    ),
  );

  File local(String path) => File('${tree.root.path}/$path');
  int scanned() => engine.lastPass!.filesHashedBy['scan'] ?? 0;
  Map<String, String> rows() => {
    for (final table in ['settings', 'entries', 'operations'])
      for (final row in store.db.select('SELECT * FROM $table'))
        '$table/${row.values.first}': '${row.values.last}',
  };

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-root-identity-');
    profile = Directory('${fixture.path}/profile');
    native = NativeRootFs();
    native.debugVolume();
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = trusted(RootTree.setup(parent.path, 'identity', native));
    store = Manifest(profile);
    store.setSetting('profileId', 'identity');
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    native.debugVolume();
    engine.close(); // Also closes the tree and the manifest.
    fixture.deleteSync(recursive: true);
  });

  void reopen() {
    store = Manifest(profile);
    tree = openTree();
    engine = SyncEngine(store, tree, cloud);
  }

  /// Restart on the same profile, optionally after a simulated reboot.
  void restart({int devOffset = 0, int? withFsid}) {
    engine.close();
    native.debugVolume(devOffset: devOffset, fsid: withFsid);
    reopen();
  }

  /// A synced tree whose stamps are recorded in the pre-fix `dev:ino` form,
  /// with the pre-fix root identity: the state of a profile written before
  /// this change.
  Future<void> legacyProfile({
    List<String> names = const ['a', 'b', 'c'],
  }) async {
    for (final name in names) {
      local('Documents/$name.txt').writeAsStringSync('content $name');
    }
    await Future<void>.delayed(settle);
    await engine.tick();
    await engine.tick();
    expect(cloud.uploads, names.length);
    final info = native.rootInfo(tree.fd);
    expect(info.stable, isFalse);
    expect(info.identity, info.legacy);
    store.setSetting('rootIdentity', info.legacy);
    expect(
      store.entries['Documents/a.txt']!.localStamp,
      startsWith('${info.legacy.split(':').first}:'),
    );
  }

  group('native identity', () {
    test('survives a reboot-style device change on a stable fsid', () {
      native.debugVolume(fsid: fsid);
      local('Documents/x.txt').writeAsStringSync('x');
      final before = native.rootInfo(tree.fd);
      final scan = tree.scanItems();
      final file = native.openRoot('${tree.root.path}/Documents');
      final eviction = EvictionNative(native);
      final info = eviction.info(tree.fd, 'Documents/x.txt');
      native.debugVolume(devOffset: 9, fsid: fsid);
      final after = native.rootInfo(tree.fd);
      expect(before.stable, isTrue);
      expect(after.identity, before.identity);
      expect(after.legacy, isNot(before.legacy));
      expect(before.identity, startsWith('f2085a06437881631:'));
      final rescanned = tree.scanItems();
      for (final path in scan.keys) {
        expect(rescanned[path]!.identity, scan[path]!.identity);
        expect(rescanned[path]!.scanStamp, scan[path]!.scanStamp);
      }
      expect(native.identity(file), startsWith('f2085a06437881631:'));
      expect(eviction.info(tree.fd, 'Documents/x.txt').identity, info.identity);
      expect(eviction.info(tree.fd, 'Documents/x.txt').stamp, info.stamp);
      native.closeFd(file);
    });

    test('without a stable fsid the identity is the previous dev:ino', () {
      final before = native.rootInfo(tree.fd);
      expect(before.stable, isFalse);
      expect(before.identity, before.legacy);
      native.debugVolume(devOffset: 9);
      expect(native.rootInfo(tree.fd).identity, isNot(before.identity));
    }, skip: legacyLinux);

    test('directory publication and removal accept the stable identity', () {
      native.debugVolume(fsid: fsid);
      tree.ensureDirectory('Documents/gone');
      final identity = tree.scanItems()['Documents/gone']!.identity!;
      expect(identity, startsWith('f'));
      native.debugVolume(devOffset: 5, fsid: fsid);
      tree.removeEmptyDirectory('Documents/gone', identity);
      expect(Directory('${tree.root.path}/Documents/gone').existsSync(), false);
    });
  });

  group('root acceptance', () {
    test('a stable identity is accepted after a reboot-style change', () {
      native.debugVolume(fsid: fsid);
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
      restart(devOffset: 4, withFsid: fsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.matched);
    });

    test('a deleted and recreated root is refused', () {
      native.debugVolume(fsid: fsid);
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
      engine.close();
      Directory('${fixture.path}/files/anj-cloud').deleteSync(recursive: true);
      Directory('${fixture.path}/files/anj-cloud').createSync();
      reopen();
      expect(acceptRoot(store, tree).outcome, RootOutcome.refused);
    });

    test('another filesystem at the path is refused', () {
      native.debugVolume(fsid: fsid);
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
      restart(devOffset: 4, withFsid: otherFsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.refused);
    });

    test('a directory renamed into place is refused', () {
      native.debugVolume(fsid: fsid);
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
      engine.close();
      final path = '${fixture.path}/files/anj-cloud';
      Directory(path).renameSync('${fixture.path}/files/old');
      Directory('${fixture.path}/files/other').createSync();
      Directory('${fixture.path}/files/other').renameSync(path);
      reopen();
      expect(acceptRoot(store, tree).outcome, RootOutcome.refused);
    });

    test('a symlink swapped in at the root path cannot be opened', () {
      native.debugVolume(fsid: fsid);
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
      engine.close();
      final path = '${fixture.path}/files/anj-cloud';
      Directory(path).renameSync('${fixture.path}/files/old');
      Link(path).createSync('${fixture.path}/files/old');
      expect(openTree, throwsA(isA<FileSystemException>()));
      Link(path).deleteSync();
      Directory('${fixture.path}/files/old').renameSync(path);
      reopen();
      expect(acceptRoot(store, tree).outcome, RootOutcome.matched);
    });
  });

  group('legacy migration', () {
    test('accepts on evidence and the index re-reads nothing', () async {
      await legacyProfile();
      final legacy = store.setting('rootIdentity')!;
      restart(devOffset: 4, withFsid: fsid);
      final result = acceptRoot(store, tree);
      expect(result.outcome, RootOutcome.migrated, reason: result.detail);
      expect(store.setting('rootIdentity'), native.rootInfo(tree.fd).identity);
      expect(store.setting('rootIdentity'), isNot(legacy));
      expect(
        store.entries['Documents/a.txt']!.localStamp,
        startsWith('f2085a06437881631:'),
      );
      await engine.tick();
      expect(scanned(), 0, reason: 'translated stamps are reused');
      expect(cloud.uploads, 3);
      expect(cloud.deletes, 0);
      // A later reboot changes nothing either.
      restart(devOffset: 11, withFsid: fsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.matched);
      await engine.tick();
      expect(scanned(), 0);
      expect(cloud.uploads, 3);
    });

    test('a pre-fix value whose device still matches upgrades', () async {
      await legacyProfile();
      restart(withFsid: fsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.upgraded);
      await engine.tick();
      expect(scanned(), 0);
    });

    String legacyDevice() => store.setting('rootIdentity')!.split(':').first;
    LegacyEvidence evaluate({void Function()? onLongCheck}) =>
        evaluateLegacyRoot(
          store,
          tree,
          legacyDevice(),
          native.rootInfo(tree.fd).identity.split(':').first,
          onLongCheck: onLongCheck,
        );

    /// Models evidence that predates the client's last observation (a
    /// rollback): the manifest says the tree was observed an hour from now,
    /// so every ctime on disk is older than R.
    void observedLater() {
      final entry = store.entries['Documents/a.txt']!;
      entry.setIndex(
        entry.localStamp,
        entry.stampHash,
        tree.wallMicros() + 3600000000,
        entry.stampFinal,
      );
      store.save();
    }

    /// A file synced and then deleted on both sides: a tombstone row.
    Future<void> tombstone(String path) async {
      local(path).writeAsStringSync('lock');
      await engine.tick();
      local(path).deleteSync();
      await engine.tick();
      expect(store.entries[path]!.expectedPresent, isFalse);
      expect(cloud.files.containsKey(path), isFalse);
    }

    const lock = 'Documents/.~lock.report.odt#';

    // Ordinary use while paused (all after R): accepted, then the normal
    // start path applies.
    for (final (name, edit) in <(String, Future<void> Function())>[
      (
        'an atomic save with a new inode',
        () async {
          final temp = local('Documents/.b.txt.tmp')
            ..writeAsStringSync('saved later');
          temp.renameSync(local('Documents/b.txt').path);
        },
      ),
      ('a delete', () async => local('Documents/c.txt').deleteSync()),
      (
        'a rename',
        () async =>
            local('Documents/a.txt')
                .renameSync(local('Documents/a-renamed.txt').path),
      ),
      (
        'a .~lock reappearing at a tombstone',
        () async {
          local(lock).writeAsStringSync('lock again');
        },
      ),
    ]) {
      test('accepts ordinary use after the last pass: $name', () async {
        await legacyProfile();
        await tombstone(lock);
        await edit();
        restart(devOffset: 4, withFsid: fsid);
        final result = acceptRoot(store, tree);
        expect(result.outcome, RootOutcome.migrated, reason: result.detail);
      });
    }

    test('a migrated profile runs the normal If-Match path', () async {
      final calls = <String>[];
      cloud = RecordingCloud(calls);
      engine.close();
      reopen();
      await legacyProfile(names: ['a', 'b', 'c', 'd']);
      await tombstone(lock);
      final etags = {
        for (final f in ['a', 'b', 'c'])
          'Documents/$f.txt': store.entries['Documents/$f.txt']!.etag,
      };
      // While paused: an atomic save, two deletes, a recreated lock file.
      final temp = local('Documents/.b.txt.tmp')
        ..writeAsStringSync('saved later');
      temp.renameSync(local('Documents/b.txt').path);
      local('Documents/a.txt').deleteSync();
      local('Documents/c.txt').deleteSync();
      local(lock).writeAsStringSync('lock again');
      // Meanwhile another device changed c.txt: its delete must not land.
      cloud.put('Documents/c.txt', 'remote edit');
      restart(devOffset: 4, withFsid: fsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.migrated);
      calls.clear();
      await engine.tick();
      expect(
        calls,
        containsAll([
          'upload Documents/b.txt If-Match ${etags['Documents/b.txt']}',
          'delete Documents/a.txt If-Match ${etags['Documents/a.txt']}',
          'upload $lock If-None-Match *',
        ]),
      );
      // c.txt changed remotely since the last sync: no delete is sent for
      // it at all and the remote version is kept.
      expect(calls.where((c) => c.startsWith('delete')), [
        'delete Documents/a.txt If-Match ${etags['Documents/a.txt']}',
      ]);
      expect(
        String.fromCharCodes(cloud.files['Documents/b.txt']!),
        'saved later',
      );
      expect(cloud.files.containsKey('Documents/a.txt'), isFalse);
      expect(
        String.fromCharCodes(cloud.files['Documents/c.txt']!),
        'remote edit',
        reason: 'no blind delete of a version this client never saw',
      );
      expect(scanned(), 2, reason: 'only the saved file and the new lock');
    });

    test('a stamp that moved before the last pass with equal bytes is '
        'content-proven after a status event', () async {
      await legacyProfile();
      local('Documents/b.txt').setLastModifiedSync(DateTime(2020));
      observedLater();
      restart(devOffset: 4, withFsid: fsid);
      var events = 0;
      final evidence = evaluate(onLongCheck: () => events++);
      expect(evidence.accepted, isTrue, reason: evidence.detail);
      expect(evidence.inodeProven, 2);
      expect(evidence.contentProven, 1);
      expect(events, 1);
    });

    test('no status event when nothing needs reading', () async {
      await legacyProfile();
      restart(devOffset: 4, withFsid: fsid);
      var events = 0;
      expect(evaluate(onLongCheck: () => events++).accepted, isTrue);
      expect(events, 0);
    });

    test(
      'journal identities recorded on the legacy device are translated',
      () async {
        await legacyProfile();
        final legacyDevice = store.setting('rootIdentity')!.split(':').first;
        final op = Operation('op1', 'evict', 'Documents/a.txt', phase: 'held');
        op.data = {
          'identity': '$legacyDevice:77',
          'previews': {
            's': {
              'stamp': '$legacyDevice:77:5:1:2:3:4',
              'name': '$legacyDevice:9',
            },
          },
          'other': '$legacyDevice:5',
          'foreign': {'identity': '999999:77'},
        };
        store.operations[op.id] = op;
        store.save();
        restart(devOffset: 4, withFsid: fsid);
        expect(acceptRoot(store, tree).outcome, RootOutcome.migrated);
        final data = store.operations['op1']!.data;
        expect(data['identity'], 'f2085a06437881631:77');
        expect((data['previews'] as Map)['s'], {
          'stamp': 'f2085a06437881631:77:5:1:2:3:4',
          'name': '$legacyDevice:9',
        });
        expect(data['other'], '$legacyDevice:5', reason: 'not an identity key');
        expect((data['foreign'] as Map)['identity'], '999999:77');
      },
    );

    // Rollback signatures: the discrepancy's evidence predates R.
    for (final (name, change) in <(String, Future<void> Function())>[
      (
        'a file missing in a folder last changed before R',
        () async {
          local('Documents/c.txt').deleteSync();
          observedLater();
        },
      ),
      (
        'a folder missing in a root last changed before R',
        () async {
          for (final f in ['a', 'b', 'c']) {
            local('Documents/$f.txt').deleteSync();
          }
          Directory('${tree.root.path}/Documents').deleteSync();
          observedLater();
        },
      ),
      (
        'bytes changed before R',
        () async {
          local('Documents/b.txt').writeAsStringSync('older bytes');
          observedLater();
        },
      ),
      (
        'a tombstoned path reappearing before R',
        () async {
          await tombstone(lock);
          local(lock).writeAsStringSync('old lock');
          observedLater();
        },
      ),
      (
        'a same-inode file whose ctime went backwards',
        () async {
          final entry = store.entries['Documents/b.txt']!;
          final v = entry.localStamp!.split(':');
          final later = int.parse(v[4]) + 1000000000;
          entry.setIndex(
            '${v[0]}:${v[1]}:${v[2]}:${v[3]}:$later',
            entry.stampHash,
            entry.stampedAt,
            entry.stampFinal,
          );
          store.save();
        },
      ),
      (
        'no file proving the same directory',
        () async {
          for (final entry in store.entries.values) {
            entry.setIndex(null, null, null);
          }
          store.save();
        },
      ),
      (
        'a changed root inode',
        () async => store.setSetting('rootIdentity', '1:1'),
      ),
    ]) {
      test('refuses: $name; nothing is written or sent', () async {
        await legacyProfile();
        await change();
        final uploads = cloud.uploads;
        final deletes = cloud.deletes;
        restart(devOffset: 4, withFsid: fsid);
        final before = rows();
        final result = acceptRoot(store, tree);
        expect(result.outcome, RootOutcome.refused, reason: result.detail);
        expect(rows(), before, reason: 'manifest untouched on refusal');
        expect(cloud.uploads, uploads);
        expect(cloud.deletes, deletes);
      });
    }

    test('the refusal is what prevents a rollback deletion', () async {
      await legacyProfile();
      local('Documents/c.txt').deleteSync();
      observedLater();
      restart(devOffset: 4, withFsid: fsid);
      expect(acceptRoot(store, tree).outcome, RootOutcome.refused);
      // Counterfactual: had the root been accepted, the next pass would have
      // treated the missing file as a local deletion and sent it.
      await engine.tick();
      expect(cloud.deletes, 1);
    });
  }, skip: legacyLinux);

  group(
    'watcher',
    () {
      test('starts on a stable-fsid root; watcher stamps match scan stamps '
          'and survive a reboot', () async {
        native.debugVolume(fsid: fsid);
        store.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
        await engine.startWatching();
        expect(engine.watcher, isNotNull, reason: 'inotify is available');
        expect(engine.watcher!.active, isTrue);
        (engine.watcher! as LocalWatcher)
          ..quiet = const Duration(milliseconds: 150)
          ..maxDelay = const Duration(seconds: 2);
        local('Documents/w.txt').writeAsStringSync('watched');
        await Future<void>.delayed(settle);
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
          if (store.entries['Documents/w.txt']?.localStamp != null) break;
        }
        final stamp = store.entries['Documents/w.txt']!.localStamp!;
        expect(stamp, startsWith('f2085a06437881631:'));
        expect(tree.scanItems()['Documents/w.txt']!.scanStamp, stamp);
        expect(tree.statItem('Documents/w.txt')!.scanStamp, stamp);
        restart(devOffset: 4, withFsid: fsid);
        expect(acceptRoot(store, tree).outcome, RootOutcome.matched);
        await engine.startWatching();
        expect(engine.watcher, isNotNull);
        await engine.tick();
        expect(
          scanned(),
          0,
          reason: 'watched restart after reboot reads nothing',
        );
      });
    },
    skip: linuxOnly(
      'the inotify LocalWatcher on a tmpfs root with an injected fsid',
    ),
  );

  group('controller', () {
    test('a stop during the folder check lets start return; the next start '
        'works', () async {
      // A legacy profile whose evidence needs a long content read: R lies
      // in the future (observed later), so big.bin must be hashed.
      local('Documents/a.txt').writeAsStringSync('content a');
      final big = local('Documents/big.bin');
      big.openSync(mode: FileMode.write)
        ..truncateSync(8 << 30) // Sparse: hashing takes many seconds.
        ..closeSync();
      const small = 'small now';
      final a = tree.scanItems()['Documents/a.txt']!;
      final later = tree.wallMicros() + 3600000000;
      store.entries['Documents/a.txt'] = Entry('Documents/a.txt', ItemKind.file)
        ..expectedPresent = true
        ..localHash = 'ha'
        ..setIndex(a.scanStamp, 'ha', later, true);
      store.entries['Documents/big.bin'] =
          Entry('Documents/big.bin', ItemKind.file)
            ..expectedPresent = true
            ..localHash = '${sha256.convert(utf8.encode(small))}';
      store.setSetting('rootIdentity', native.rootInfo(tree.fd).legacy);
      store.save();
      engine.close();
      native.debugVolume(devOffset: 4, fsid: fsid);
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        stopTimeout: const Duration(seconds: 1),
        nativeLibrary: testNativeLibrary,
      );
      try {
        final starting = controller.initialize();
        for (
          var i = 0;
          i < 200 && controller.message != rootCheckMessage;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(controller.message, rootCheckMessage);
        await controller.stop(); // As pair() does before re-pairing.
        await starting.timeout(const Duration(seconds: 10));
        // The next start completes the check and becomes ready.
        big.writeAsStringSync(small);
        await controller.start().timeout(const Duration(seconds: 20));
        for (var i = 0; i < 200 && !controller.canCreateFolder; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(controller.canCreateFolder, isTrue, reason: controller.message);
      } finally {
        await controller.stop();
        controller.dispose();
        reopen();
      }
    });
  }, skip: legacyLinux);

  group('worker', () {
    /// Runs the real worker isolate on the profile; the caller has closed
    /// the test's engine (and with it the manifest) and reopens afterwards.
    Future<Map> firstEvent() async {
      final output = ReceivePort();
      final events = StreamIterator<dynamic>(output);
      final worker = await Isolate.spawn(syncWorker, {
        'output': output.sendPort,
        'nativeLibrary': testNativeLibrary,
        'profile': profile.path,
        'privateKey': null,
      });
      try {
        expect(
          await events.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        final event = Map<dynamic, dynamic>.from(events.current as Map);
        if (event['event'] == 'ready') {
          (event['input'] as SendPort).send({'action': 'stop'});
          do {
            expect(
              await events.moveNext().timeout(const Duration(seconds: 10)),
              true,
            );
          } while ((events.current as Map)['event'] != 'stopped');
        }
        return event;
      } finally {
        worker.kill(priority: Isolate.immediate);
        await events.cancel();
        output.close();
      }
    }

    test(
      'a profile paused by the btrfs device change recovers by itself',
      () async {
        await legacyProfile();
        engine.close();
        native.debugVolume(devOffset: 4, fsid: fsid);
        final event = await firstEvent();
        expect(event['event'], 'ready', reason: '$event');
        reopen();
        expect(
          store.setting('rootIdentity'),
          native.rootInfo(tree.fd).identity,
        );
      },
    );

    test('a refused root stays paused with the previous message', () async {
      await legacyProfile();
      local('Documents/c.txt').deleteSync();
      engine.close();
      reopen();
      final entry = store.entries['Documents/a.txt']!;
      entry.setIndex(
        entry.localStamp,
        entry.stampHash,
        tree.wallMicros() + 3600000000,
        entry.stampFinal,
      );
      store.save();
      engine.close();
      native.debugVolume(devOffset: 4, fsid: fsid);
      final event = await firstEvent();
      expect(event['event'], 'fatal');
      expect(
        event['message'],
        'Paused: root unavailable or replaced. No deletions inferred.',
      );
      reopen();
      expect(store.entries['Documents/c.txt']!.expectedPresent, isTrue);
    });
  }, skip: legacyLinux);
}

/// Records each conditional request the engine sends.
class RecordingCloud extends FakeCloud {
  RecordingCloud(this.calls);
  final List<String> calls;
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    calls.add(
      etag == null
          ? 'upload $path If-None-Match *'
          : 'upload $path If-Match $etag',
    );
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    calls.add('delete $path If-Match $etag');
    return super.deleteFile(path, etag: etag);
  }
}
