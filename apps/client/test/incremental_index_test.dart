import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

/// Spec #13 acceptance: persistent local index, diff-only writes, candidate
/// passes and deadline scheduling. Counters come from `SyncEngine.lastPass`.
// macOS only (spec #31 M1, decision #129): every manifest commit there is an
// F_FULLFSYNC (about 5 ms on mac-test), so these 1,000- and 2,000-file runs
// take 1.5 to 3.5 minutes (PR #59) against seconds on Linux's tmpfs. Only the
// limit differs; every assertion is the same.
final Timeout? flushBound =
    Platform.isMacOS ? const Timeout(Duration(minutes: 6)) : null;

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  // Files must be older than the racy-timestamp margin before their first
  // hash can be trusted; tests that need trusted stamps wait it out.
  const settle = Duration(milliseconds: 2100);

  // Test fixtures live on tmpfs, which the product never trusts (its pages
  // are never written back). Fast-path tests model a trusted filesystem with
  // periodic writeback; tests of the untrusted paths remove the seam.
  // Writeback sysctls come from a fake directory (defaults: 30 s expire,
  // 15 s interval, laptop mode off, so M = 90 s) for deterministic tests.
  const ext4 = 0xEF53;
  void setVm({int expire = 3000, int interval = 1500, int? laptop = 0}) {
    final vm = Directory('${fixture.path}/vm')..createSync(recursive: true);
    File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('$expire\n');
    File('${vm.path}/dirty_writeback_centisecs')
        .writeAsStringSync('$interval\n');
    final laptopFile = File('${vm.path}/laptop_mode');
    if (laptop == null) {
      if (laptopFile.existsSync()) laptopFile.deleteSync();
    } else {
      laptopFile.writeAsStringSync('$laptop\n');
    }
  }

  RootTree trusted(RootTree value) {
    setVm();
    return value
      ..debugFsMagic = ext4
      ..vmDirectory = '${fixture.path}/vm';
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-index-test-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = trusted(RootTree.setup(parent.path, 'index', NativeRootFs()));
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${tree.root.path}/$path');
  int scanned() => engine.lastPass!.filesHashedBy['scan'] ?? 0;
  void populate(int count, {int perDirectory = 100}) {
    for (var i = 0; i < count; i++) {
      final directory = 'Documents/d${i ~/ perDirectory}';
      if (i % perDirectory == 0) tree.ensureDirectory(directory);
      local('$directory/f$i.txt').writeAsStringSync('content of file $i');
    }
  }

  /// Exact nanosecond mtime from the native scan (Dart exposes only ms).
  int mtimeNs(String path) =>
      tree.native.scan(tree.fd).singleWhere((v) => v['path'] == path)['mtime']
          as int;
  Future<void> touchNs(File file, int ns) => setMtimeNs(file, ns);

  test(
    'idle passes after initial sync hash nothing and write nothing',
    () async {
      store.verifyTracking = false;
      populate(2000);
      await Future<void>.delayed(settle);
      await engine.tick();
      expect(cloud.files.length, 2000);
      expect(engine.lastPass!.full, isTrue);
      expect(scanned(), 2000);
      for (var i = 0; i < 3; i++) {
        await engine.tick();
        expect(engine.lastPass!.completed, isTrue);
        expect(engine.lastPass!.filesHashed, 0);
        expect(engine.lastPass!.bytesHashed, 0);
      }
      // The last pass is fully idle: no candidate, row or transaction.
      expect(engine.lastPass!.full, isFalse);
      expect(engine.lastPass!.pathsVisited, 0);
      expect(engine.lastPass!.rowsWritten, 0);
      expect(engine.lastPass!.transactions, 0);
      expect(cloud.uploads, 2000);
    },
    timeout: flushBound,
    // Idle passes skip hashing only on trusted writeback stamps (#39);
    // macOS has none, and without its watcher every pass hashes (decision
    // #135; event-driven hashing is scan_cost_macos_test.dart).
    skip: linuxOnly('idle passes rely on trusted writeback stamps (#39)'),
  );

  group('changed content is detected through the stamp', () {
    const path = 'Documents/a.txt';
    setUp(() async {
      local(path).writeAsStringSync('aaaa-1');
      await Future<void>.delayed(settle);
      await engine.tick();
      await engine.tick();
      expect(engine.lastPass!.filesHashed, 0, reason: 'fast path engaged');
      expect(cloud.uploads, 1);
    });
    Future<void> expectOneUpload(String content) async {
      await engine.tick();
      expect(scanned(), 1);
      expect(engine.lastPass!.filesHashedBy['upload-snapshot'], 1);
      expect(cloud.uploads, 2);
      expect(String.fromCharCodes(cloud.files[path]!), content);
      await engine.tick();
      expect(cloud.uploads, 2);
    }

    test('same-size edit', () async {
      local(path).writeAsStringSync('aaaa-2');
      await expectOneUpload('aaaa-2');
    });
    test('edit then mtime reset to the exact old nanosecond', () async {
      final old = mtimeNs(path);
      local(path).writeAsStringSync('aaaa-3');
      await touchNs(local(path), old);
      expect(mtimeNs(path), old);
      await expectOneUpload('aaaa-3');
    });
    test('atomic replace by rename with the old mtime', () async {
      final old = mtimeNs(path);
      final next = local('Documents/.a.txt.next')..writeAsStringSync('aaaa-4');
      await touchNs(next, old);
      next.renameSync(local(path).path);
      expect(mtimeNs(path), old);
      await expectOneUpload('aaaa-4');
    });
  });

  group('racy timestamp guard', () {
    // Model a filesystem whose stamps cannot separate two writes: same size,
    // whole-second mtime, no ctime. Only the hash's age then protects us.
    const path = 'Documents/racy.txt';
    String coarse(String stamp) {
      final v = stamp.split(':');
      final second = int.parse(v[3]) ~/ 1000000000 * 1000000000;
      return '${v[0]}:${v[1]}:${v[2]}:$second:$second';
    }

    test('write within the margin after hashing is rehashed', () async {
      tree.debugStampView = coarse;
      local(path).writeAsStringSync('racy-1');
      final first = mtimeNs(path);
      await engine.tick();
      expect(cloud.uploads, 1);
      local(path).writeAsStringSync('racy-2');
      await touchNs(local(path), first);
      await engine.tick();
      expect(scanned(), 1);
      expect(cloud.uploads, 2);
      expect(String.fromCharCodes(cloud.files[path]!), 'racy-2');
    });
    test(
      'control: the same edit is invisible to an old trusted hash',
      () async {
        local(path).writeAsStringSync('racy-1');
        await Future<void>.delayed(settle);
        await engine.tick();
        tree.debugStampView = coarse;
        final first = mtimeNs(path);
        local(path).writeAsStringSync('racy-2');
        await touchNs(local(path), first);
        await engine.tick();
        // Under this (unsafe) stamp model the reuse is exactly what the guard
        // prevents above, so the guard is the protection being exercised.
        expect(scanned(), 0);
        expect(cloud.uploads, 1);
      },
    );
  });

  group('fast path off', () {
    Future<void> expectOffEveryPass(void Function() disable) async {
      populate(50);
      await Future<void>.delayed(settle);
      await engine.tick();
      await engine.tick();
      expect(engine.lastPass!.filesHashed, 0);
      disable();
      final rows = <int>[];
      for (var i = 0; i < 3; i++) {
        await engine.tick();
        expect(scanned(), 50);
        rows.add(engine.lastPass!.rowsWritten);
      }
      // The first pass drops the stored stamps; later passes store none.
      expect(rows.skip(1), everyElement(0));
      expect(store.entries.values.where((e) => e.localStamp != null), isEmpty);
      trusted(tree);
      await engine.tick();
      expect(scanned(), 50, reason: 're-stamped once when trusted again');
      await engine.tick();
      expect(engine.lastPass!.filesHashed, 0);
      expect(engine.lastPass!.rowsWritten, 0);
    }

    test('untrusted filesystem type (FAT) hashes every file every pass', () {
      return expectOffEveryPass(() => tree.debugFsMagic = 0x4d44);
    });
    test('tmpfs hashes every file every pass', () {
      return expectOffEveryPass(() {
        tree.debugFsMagic = null;
        expect(tree.native.fsMagic(tree.fd, ''), 0x01021994);
      });
    }, skip: linuxOnly('the fixture directory is on tmpfs only on the VM host'));
    test('disabled periodic writeback hashes every file every pass', () {
      return expectOffEveryPass(() => setVm(interval: 0));
    });
  });

  group('confirmation hash (decision #38)', () {
    test(
      'a future mtime is confirmed once, then reused without writes',
      () async {
        tree.debugConfirmMicros = 3000000;
        const path = 'Documents/future.txt';
        local(path).writeAsStringSync('from the future');
        // A year ahead, as `touch -m -d '+1 year'` (GNU only) set it.
        await setMtimeNs(
          local(path),
          DateTime.now().add(const Duration(days: 365)).microsecondsSinceEpoch *
              1000,
        );
        await Future<void>.delayed(settle);
        await engine.tick();
        expect(scanned(), 1);
        expect(store.entries[path]!.stampFinal, isFalse);
        await engine.tick();
        expect(scanned(), 0, reason: 'the mtime alone never forces a rehash');
        expect(store.entries[path]!.stampFinal, isFalse);
        await Future<void>.delayed(const Duration(seconds: 3));
        await engine.tick();
        expect(scanned(), 1, reason: 'one confirmation hash after M');
        expect(store.entries[path]!.stampFinal, isTrue);
        for (var i = 0; i < 3; i++) {
          await engine.tick();
          expect(scanned(), 0);
          expect(engine.lastPass!.rowsWritten, 0);
        }
        expect(cloud.uploads, 1);
      },
    );

    test('a shared-mmap write to an already dirty page is uploaded by confirmation', () async {
      // Real writeback semantics need a real disk; .dart_tool is ignored.
      final disk = Directory('.dart_tool/anj-disk-fixtures')
        ..createSync(recursive: true);
      final base = disk.createTempSync('mmap-');
      final parent = Directory('${base.path}/files')..createSync();
      final diskTree = RootTree.setup(parent.path, 'disk', NativeRootFs());
      final diskStore = Manifest(Directory('${base.path}/profile'))
        ..setSetting('retention', 'local');
      final diskCloud = FakeCloud();
      final diskEngine = SyncEngine(diskStore, diskTree, diskCloud);
      Process? writer;
      try {
        // Real filesystem and real /proc writeback settings; only M is cut.
        diskTree.debugConfirmMicros = 4000000;
        const path = 'Documents/db.bin';
        final file = File('${diskTree.root.path}/$path')
          ..writeAsStringSync('mmap-0000');
        await Future<void>.delayed(settle);
        await diskEngine.tick();
        final magic = diskTree.native.fsMagic(diskTree.fd, '');
        if (!NativeRootFs.trustedMagic.contains(magic) ||
            !diskTree.writebackEnabled) {
          markTestSkipped(
            'needs a trusted disk filesystem with writeback (0x${magic.toRadixString(16)})',
          );
          return;
        }
        await diskEngine.tick();
        expect(diskCloud.uploads, 1);
        expect(diskEngine.lastPass!.filesHashed, 0);
        writer = await Process.start('python3', [
          '-I',
          '-c',
          'import mmap,sys\n'
              'f=open(sys.argv[1],"r+b");m=mmap.mmap(f.fileno(),0)\n'
              'print("ready",flush=True)\n'
              'for line in sys.stdin:\n'
              ' o,c=line.split();m[int(o)]=ord(c);print("ok",flush=True)',
          file.path,
        ]);
        final lines = writer.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();
        Future<void> write(int offset, String char) async {
          final ack = lines.first;
          writer!.stdin.writeln('$offset $char');
          await writer.stdin.flush();
          expect(await ack, 'ok');
        }

        expect(await lines.first, 'ready');
        await write(0, 'A');
        await diskEngine.tick();
        expect(String.fromCharCodes(diskCloud.files[path]!), 'Amap-0000');
        // The hash read within the racy margin is read once more; after
        // that the stamp is reused (not yet final).
        await Future<void>.delayed(settle);
        await diskEngine.tick();
        expect(diskEngine.lastPass!.filesHashedBy['scan'], 1);
        await diskEngine.tick();
        expect(diskEngine.lastPass!.filesHashed, 0);
        expect(diskStore.entries[path]!.stampFinal, isFalse);
        final stamp = diskStore.entries[path]!.localStamp;
        // Same, still dirty page: no mtime/ctime change, identical stamp.
        await write(1, 'B');
        await diskEngine.tick();
        expect(diskStore.entries[path]!.localStamp, stamp);
        expect(diskEngine.lastPass!.filesHashedBy['scan'] ?? 0, 0);
        await Future<void>.delayed(const Duration(seconds: 4));
        await diskEngine.tick();
        expect(diskEngine.lastPass!.filesHashedBy['scan'], 1);
        await diskEngine.tick();
        expect(String.fromCharCodes(diskCloud.files[path]!), 'ABap-0000');
        expect(file.readAsStringSync(), 'ABap-0000');
      } finally {
        writer?.kill();
        await writer?.exitCode;
        diskEngine.close();
        base.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    // Coarse stamps (whole-second mtime, no ctime) make a write invisible to
    // the stamp, as a shared-mmap write to a dirty page is.
    String coarse(String stamp) {
      final v = stamp.split(':');
      final second = int.parse(v[3]) ~/ 1000000000 * 1000000000;
      return '${v[0]}:${v[1]}:${v[2]}:$second:$second';
    }

    test(
      'a forward wall-clock step never finalizes before M of monotonic time',
      () async {
        tree.debugConfirmMicros = 3000000;
        tree.debugStampView = coarse;
        const path = 'Documents/clock.bin';
        local(path).writeAsStringSync('Alok-0000');
        final mtime = mtimeNs(path);
        await Future<void>.delayed(settle);
        await engine.tick();
        expect(scanned(), 1);
        // NTP or a local-time RTC steps the wall clock far past M.
        const step = 3000000 + 10000000;
        tree.wallMicros = () => DateTime.now().microsecondsSinceEpoch + step;
        await engine.tick();
        expect(scanned(), 0, reason: 'no confirmation before monotonic M');
        expect(store.entries[path]!.stampFinal, isFalse);
        // A write the stamp cannot see, as through a still-dirty mapped page.
        local(path).writeAsStringSync('ABok-0000');
        await touchNs(local(path), mtime);
        await engine.tick();
        expect(scanned(), 0);
        expect(String.fromCharCodes(cloud.files[path]!), 'Alok-0000');
        await Future<void>.delayed(const Duration(seconds: 3));
        await engine.tick();
        expect(scanned(), 1, reason: 'confirmation after monotonic M');
        expect(store.entries[path]!.stampFinal, isTrue);
        expect(String.fromCharCodes(cloud.files[path]!), 'ABok-0000');
      },
    );

    test(
      'writeback sysctls are re-read every pass; laptop mode turns reuse off',
      () async {
        tree.confirmFloorMicros = 1000000;
        setVm(expire: 50, interval: 25); // M = 1.5 s
        const path = 'Documents/battery.txt';
        local(path).writeAsStringSync('on battery');
        await Future<void>.delayed(settle);
        await engine.tick();
        expect(tree.confirmMicros, 1500000);
        expect(scanned(), 1);
        expect(store.entries[path]!.stampFinal, isFalse);
        // A power tool raises writeback on battery: M becomes 6 s.
        setVm(expire: 250, interval: 50);
        await Future<void>.delayed(const Duration(seconds: 2));
        await engine.tick();
        expect(tree.confirmMicros, 6000000);
        expect(scanned(), 0, reason: 'the larger M applies to unfinal hashes');
        expect(store.entries[path]!.stampFinal, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 4200));
        await engine.tick();
        expect(scanned(), 1);
        expect(store.entries[path]!.stampFinal, isTrue);
        await engine.tick();
        expect(scanned(), 0);
        setVm(expire: 250, interval: 50, laptop: 1);
        await engine.tick();
        expect(tree.writebackEnabled, isFalse);
        expect(scanned(), 1);
        expect(store.entries[path]!.localStamp, isNull);
        await engine.tick();
        expect(scanned(), 1);
        expect(engine.lastPass!.rowsWritten, 0);
        setVm(expire: 250, interval: 50, laptop: null); // unreadable
        await engine.tick();
        expect(tree.writebackEnabled, isFalse);
        expect(scanned(), 1);
        expect(engine.lastPass!.rowsWritten, 0);
        setVm();
        await engine.tick();
        expect(tree.writebackEnabled, isTrue);
        expect(store.entries[path]!.localStamp, isNotNull);
      },
    );
  });

  test(
    'offline passes compare all manifest rows once, not every pass',
    () async {
      populate(20);
      await engine.tick();
      final audits = engine.rowAudits;
      cloud.online = false;
      engine.auditInterval = Duration.zero;
      for (var i = 0; i < 3; i++) {
        await engine.tick();
        expect(engine.message, startsWith('Offline'));
      }
      expect(engine.rowAudits, audits + 1);
      cloud.online = true;
      await engine.tick();
      expect(engine.lastPass!.full, isTrue);
      expect(
        engine.rowAudits,
        audits + 1,
        reason: 'same audit cycle completes',
      );
      engine.auditInterval = const Duration(minutes: 5);
      await engine.tick();
      expect(engine.lastPass!.full, isFalse);
    },
  );

  test(
    'entries without a stamp are hashed once and stamped (migration)',
    () async {
      populate(20);
      await Future<void>.delayed(settle);
      await engine.tick();
      engine.close();
      final reopened = Manifest(Directory('${fixture.path}/profile'));
      for (final entry in reopened.entries.values) {
        entry.setIndex(null, null, null);
      }
      reopened.save();
      reopened.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      tree = trusted(RootTree(tree.root, tree.staging, NativeRootFs()));
      engine = SyncEngine(store, tree, cloud);
      await engine.tick();
      expect(scanned(), 20);
      expect(
        store.entries.values
            .where((e) => e.kind == ItemKind.file)
            .every((e) => e.localStamp != null && e.stampHash == e.localHash),
        isTrue,
      );
      await engine.tick();
      expect(engine.lastPass!.filesHashed, 0);
    },
  );

  test(
    'single-file change writes the same rows at 200 and 2000 files',
    () async {
      store.verifyTracking = false;
      Future<(int, int)> changeOne(String path) async {
        await Future<void>.delayed(settle);
        await engine.tick();
        await engine.tick();
        await engine.tick();
        expect(engine.lastPass!.rowsWritten, 0);
        local(path).writeAsStringSync('changed content!');
        await engine.tick();
        final changed = engine.lastPass!;
        await engine.tick();
        return (
          changed.rowsWritten + engine.lastPass!.rowsWritten,
          changed.transactions + engine.lastPass!.transactions,
        );
      }

      populate(200);
      final small = await changeOne('Documents/d0/f0.txt');
      populate(2000);
      for (var i = 200; i < 2000; i++) {
        expect(local('Documents/d${i ~/ 100}/f$i.txt').existsSync(), isTrue);
      }
      final large = await changeOne('Documents/d0/f1.txt');
      expect(store.entries.length, greaterThan(2000));
      expect(large, small);
      expect(large.$1, lessThan(40));
    },
    timeout: flushBound,
  );

  group('mandatory content checks still read bytes', () {
    // An ordinary folder: Documents, Music and Videos are never Cloud-only
    // (spec #34 P7).
    const path = 'Library/kept.txt';
    setUp(() async {
      tree.ensureDirectory('Library');
      local(path).writeAsStringSync('synchronized bytes');
      await Future<void>.delayed(settle);
      await engine.tick();
      await engine.tick();
      expect(engine.lastPass!.filesHashed, 0);
    });
    test('download replacement re-reads the trusted local file', () async {
      cloud.put(path, 'newer cloud bytes');
      await engine.tick();
      expect(engine.lastPass!.filesHashedBy['replace-check'], 1);
      expect(scanned(), 0);
      expect(local(path).readAsStringSync(), 'newer cloud bytes');
    });
    test('both-changed conflict reads the remote copy', () async {
      cloud.put(path, 'remote edit');
      local(path).writeAsStringSync('local edit!');
      await engine.tick();
      expect(engine.lastPass!.filesHashedBy['conflict'], greaterThan(0));
      expect(store.entries[path]!.conflict, isNotNull);
    });
    test('eviction proves and guards the trusted local file', () async {
      final before = tree.native.meter.filesBy['eviction'] ?? 0;
      engine.setRetention('Library', Retention.cloud);
      await engine.tick();
      expect(local(path).existsSync(), isFalse);
      expect(
        (tree.native.meter.filesBy['eviction'] ?? 0) - before,
        greaterThanOrEqualTo(2),
      );
      expect(store.entries[path]!.status, 'cloud-only');
    });
    test('working copy and Finish editing read their bytes', () async {
      final work = File(await engine.openFile(path));
      work.writeAsStringSync('edited in editor', flush: true);
      await engine.tick();
      expect(engine.lastPass!.filesHashedBy['working'], greaterThan(0));
      expect(String.fromCharCodes(cloud.files[path]!), 'edited in editor');
      engine.editing.request(
        path,
        engine
            .workingCopies(path)
            .map((v) => Map<String, dynamic>.from(v))
            .toList(),
      );
      engine.markDirty(path);
      await engine.tick();
      expect(engine.lastPass!.filesHashedBy['finish-editing'], greaterThan(0));
      expect(engine.workingCopies(path), isEmpty);
    });
  });

  test(
    'a failed transfer is retried on the next pass, not the audit',
    () async {
      cloud.put('Documents/remote.txt', 'remote bytes');
      cloud.failDownloads = 1;
      await engine.tick();
      expect(
        store.entries['Documents/remote.txt']!.status,
        startsWith('pending'),
      );
      await engine.tick();
      expect(engine.lastPass!.full, isFalse);
      expect(local('Documents/remote.txt').readAsStringSync(), 'remote bytes');
    },
  );

  test(
    'blocked descendants are revisited after their folder uploads',
    () async {
      await engine.tick();
      final folder = await engine.createFolder(
        'Documents',
        'New',
        Retention.local,
      );
      local('$folder/child.txt').writeAsStringSync('child bytes');
      for (var i = 0; i < 3; i++) {
        await engine.tick();
      }
      expect(cloud.directories, contains(folder));
      expect(
        String.fromCharCodes(cloud.files['$folder/child.txt']!),
        'child bytes',
      );
    },
  );

  test(
    'retention change reconciles unchanged descendants without an audit',
    () async {
      // An ordinary folder: Documents, Music and Videos are never
      // Cloud-only (spec #34 P7).
      tree.ensureDirectory('Library');
      local('Library/x.txt').writeAsStringSync('x');
      // New folders settle in three passes: create, adopt ETag, confirm.
      for (var i = 0; i < 4; i++) {
        await engine.tick();
      }
      expect(engine.lastPass!.pathsVisited, 0);
      engine.setRetention('Library', Retention.cloud);
      await engine.tick();
      expect(engine.lastPass!.full, isFalse);
      expect(engine.lastPass!.pathsVisited, 2);
      expect(local('Library/x.txt').existsSync(), isFalse);
    },
  );

  test('audit timer reconciles every path', () async {
    populate(30);
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(engine.lastPass!.pathsVisited, 0);
    engine.auditInterval = Duration.zero;
    await engine.tick();
    expect(engine.lastPass!.full, isTrue);
    expect(engine.lastPass!.pathsVisited, store.entries.length);
  });

  group('worker loop', () {
    test(
      'a command during a 10k-file pass completes within one path',
      () async {
        store.verifyTracking = false;
        populate(10000);
        final seeded = await tree.snapshot();
        for (final item in seeded.values) {
          final version = '"seed-${item.path}"';
          store.entries[item.path] = Entry(item.path, item.kind)
            ..etag = version
            ..baselineHash = item.hash
            ..localHash = item.hash
            ..expectedPresent = true
            ..status = 'current local'
            ..size = item.size;
          if (item.kind == ItemKind.directory) {
            cloud.directories.add(item.path);
          } else {
            cloud.files[item.path] = local(item.path).readAsBytesSync();
          }
          cloud.versions[item.path] = version;
        }
        store.save();
        final input = StreamController<Object?>();
        final events = <Map>[];
        int? visitedAtReply;
        int? passesAtReply;
        final sent = Completer<void>();
        final injecting = _InjectingCloud(cloud, () {
          if (sent.isCompleted) return;
          sent.complete();
          input.add({'action': 'openDirectory', 'path': 'Documents/d7'});
        });
        engine.close();
        store = Manifest(Directory('${fixture.path}/profile'))
          ..verifyTracking = false;
        tree = trusted(RootTree(tree.root, tree.staging, NativeRootFs()));
        engine = SyncEngine(store, tree, injecting);
        final loop = WorkerLoop(engine, (event) {
          final map = event as Map;
          events.add(map);
          if (map['event'] == 'openDirectory') {
            visitedAtReply = engine.visitedThisPass;
            passesAtReply = engine.passes;
          }
          if (map['event'] == 'state' && engine.passes == 1) {
            input.add({'action': 'stop'});
          }
        }, interval: const Duration(hours: 1));
        await loop.run(input.stream).timeout(const Duration(minutes: 3));
        await input.close();
        expect(passesAtReply, 0, reason: 'answered inside the first pass');
        expect(visitedAtReply, lessThanOrEqualTo(1));
        expect(engine.lastPass!.pathsVisited, greaterThan(10000));
        expect(events.last['event'], 'stopped');
        // The loop closed the engine; give tearDown fresh handles.
        store = Manifest(Directory('${fixture.path}/profile'));
        tree = trusted(RootTree(tree.root, tree.staging, NativeRootFs()));
        engine = SyncEngine(store, tree, cloud);
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );

    test('passes start a deadline after the previous one ends and emit only changes', () async {
      final starts = <DateTime>[];
      final input = StreamController<Object?>();
      // Stop after a fixed number of listings, not after a wall-clock
      // window: the pass in flight ends at its next path boundary and is
      // still recorded.
      const listings = 5;
      final slow = _InjectingCloud(
        cloud,
        () {
          if (starts.length == listings) input.add({'action': 'stop'});
        },
        delay: const Duration(milliseconds: 300),
        starts: starts,
      );
      engine.close();
      store = Manifest(Directory('${fixture.path}/profile'));
      tree = trusted(RootTree(tree.root, tree.staging, NativeRootFs()));
      engine = SyncEngine(store, tree, slow);
      local('Documents/m.txt').writeAsStringSync('metrics');
      // Older than the racy-timestamp margin before the first pass reads it,
      // so that read is trusted and every later pass reuses it. Otherwise
      // whether the last pass still re-reads the file depends on where pass
      // starts fall against the 2 s margin.
      await Future<void>.delayed(settle);
      final metrics = File('${fixture.path}/metrics.jsonl');
      final loop = WorkerLoop(
        engine,
        (_) {},
        interval: const Duration(milliseconds: 200),
        metrics: metrics,
        // List the cloud on every pass here (spec #16 idle cadence is 30 s).
        schedule: RemoteSchedule(idle: const Duration(milliseconds: 200)),
      );
      await loop.run(input.stream).timeout(const Duration(seconds: 20));
      await input.close();
      expect(starts.length, listings);
      for (var i = 1; i < starts.length; i++) {
        // 300 ms pass + 200 ms deadline (measured ~503 ms): never back to
        // back, and never a slower cadence. The 650 ms ceiling leaves ~150 ms
        // for load and still fails a doubled interval (~700 ms).
        expect(
          starts[i].difference(starts[i - 1]).inMilliseconds,
          allOf(greaterThanOrEqualTo(480), lessThan(650)),
          reason: 'spacing before listing $i',
        );
      }
      final lines = metrics
          .readAsLinesSync()
          .map((v) => jsonDecode(v) as Map)
          .toList();
      // The listing falls due exactly one interval after each pass, so a
      // pass that starts no earlier than its deadline always lists; one that
      // fires early (a truncated millisecond timer) records local state only
      // and pushes the listing a whole interval later.
      expect(
        lines.length,
        starts.length,
        reason: 'every pass listed the cloud: none started before its deadline',
      );
      for (final key in [
        'filesHashed',
        'bytesHashed',
        'rowsWritten',
        'transactions',
        'durationMicros',
        'candidates',
        'full',
      ]) {
        expect(lines.last.containsKey(key), isTrue, reason: key);
      }
      // Later idle passes change nothing, so no state is re-sent.
      expect(lines.last['emitted'], lines[lines.length - 2]['emitted']);
      // The first pass reads the settled file once; every later pass reuses
      // its trusted stamp and reads nothing.
      expect((lines.first['filesHashedBy'] as Map)['scan'], 1);
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i]['filesHashed'], 0, reason: 'pass ${i + 1}');
      }
      store = Manifest(Directory('${fixture.path}/profile'));
      tree = trusted(RootTree(tree.root, tree.staging, NativeRootFs()));
      engine = SyncEngine(store, tree, cloud);
    });
  });
}

/// Delegates to [FakeCloud]; runs [onSnapshot] when a pass lists the cloud.
class _InjectingCloud extends FakeCloud {
  _InjectingCloud(
    this.inner,
    this.onSnapshot, {
    this.delay = Duration.zero,
    this.starts,
  });
  final FakeCloud inner;
  final void Function() onSnapshot;
  final Duration delay;
  final List<DateTime>? starts;
  @override
  Future<List<RemoteItem>> snapshot() async {
    starts?.add(DateTime.now());
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final result = await inner.snapshot();
    onSnapshot();
    return result;
  }

  @override
  Future<void> download(String path, File target, {required String etag}) =>
      inner.download(path, target, etag: etag);
  @override
  Future<String> upload(String path, File source, {required String? etag}) =>
      inner.upload(path, source, etag: etag);
  @override
  Future<void> mkdir(String path) => inner.mkdir(path);
  @override
  Future<void> deleteFile(String path, {required String etag}) =>
      inner.deleteFile(path, etag: etag);
}
