// Mac-side M2b tests (decision #135, flag SC-051): event-driven hashing on
// the FSEvents watcher's APFS root, the F_BARRIERFSYNC / F_FULLFSYNC calls
// of grouped manifest commits, and the per-path sync cost with and without
// grouping, measured in one run. Run on mac-test by check_macos.sh.
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_commit_durability.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';

import '../test/fakes.dart';

void main() {
  final library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];
  late Directory fixture;

  setUp(() {
    if (library == null) fail('ANJ_MACOS_ROOTFS_LIBRARY is not set');
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-m2b-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  Future<SyncEngine> engineAt(String name, {bool groupCommits = true}) async {
    final parent = Directory('${fixture.path}/$name/files')
      ..createSync(recursive: true);
    final tree = RootTree.setup(
      parent.path,
      'root',
      const MacosPlatformAdapters().rootFilesystem(library),
    );
    final store = Manifest(
      Directory('${fixture.path}/$name/profile'),
      groupCommits: groupCommits,
    )..setSetting('retention', 'local');
    final engine = SyncEngine(store, tree, FakeCloud());
    await engine.startWatching();
    expect(engine.watcher, isNotNull, reason: 'APFS root: FSEvents');
    (engine.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
    return engine;
  }

  test('the barrier and the full flush reach the file', () {
    final file = File('${fixture.path}/sync-target')..writeAsStringSync('x');
    const durability = MacosCommitDurability();
    durability.barrier(file.path);
    durability.flush(file.path);
    expect(
      () => durability.barrier('${fixture.path}/missing'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('the macOS manifest groups commits behind barriers', () {
    final m = Manifest(Directory('${fixture.path}/profile'));
    try {
      expect(m.groupsCommits, isTrue);
      expect(m.db.select('PRAGMA fullfsync').first.values.first, 0);
      expect(m.db.select('PRAGMA checkpoint_fullfsync').first.values.first, 1);
      m.setSetting('k', 'v');
      expect(m.flushes, 1);
      expect(m.groupingDisabled, isFalse);
    } finally {
      m.close();
    }
  });

  test(
    'event-driven: the first pass verifies, idle passes hash nothing',
    () async {
      final engine = await engineAt('idle');
      try {
        final root = engine.tree.root.path;
        for (var i = 0; i < 30; i++) {
          File('$root/f$i.txt').writeAsStringSync('file $i');
        }
        await engine.tick();
        expect(engine.eventDriven, isTrue);
        expect(engine.fullVerifications, 1);
        var calm = 0;
        for (var i = 0; i < 60 && calm < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await engine.tick();
          calm = engine.lastPass!.filesHashed == 0 ? calm + 1 : 0;
        }
        expect(calm, 4, reason: 'idle passes read no file');
        expect(engine.lastPass!.localScan, 'partial');
        expect(engine.fullVerifications, 1);
        File('$root/f3.txt').writeAsStringSync('changed');
        var hashed = 0;
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
          hashed += engine.lastPass!.filesHashedBy['scan'] ?? 0;
          if (hashed > 0 && engine.watcher!.nextDeadline() == null) break;
        }
        expect(
          hashed,
          inInclusiveRange(1, 2),
          reason: 'only the reported file',
        );
      } finally {
        engine.close();
      }
    },
  );

  test('barrier and full flush on the manifest WAL through a read-only fd', () {
    final m = Manifest(Directory('${fixture.path}/wal-profile'));
    try {
      m.setSetting('k', 'v');
      for (var i = 0; i < 5; i++) {
        m.setSetting('k$i', 'v');
      }
      final wal = File('${fixture.path}/wal-profile/manifest.sqlite-wal');
      expect(wal.existsSync(), isTrue);
      const durability = MacosCommitDurability();
      durability.barrier(wal.path);
      durability.flush(wal.path);
      expect(m.groupingDisabled, isFalse);
      expect(m.flushes, greaterThanOrEqualTo(6));
    } finally {
      m.close();
    }
  });

  test(
    'APFS: the old spelling of a case-only or NFC/NFD rename reports its '
    'stored name; the engine follows both renames by events (#138)',
    () async {
      final engine = await engineAt('names');
      try {
        final root = engine.tree.root.path;
        final fs = engine.tree.native;
        final cloud = engine.cloud as FakeCloud;
        const nfc = 'caf\u00e9.txt', nfd = 'cafe\u0301.txt';
        Directory('$root/Docs').createSync();
        File('$root/Docs/Report.txt').writeAsStringSync('report');
        File('$root/Docs/$nfc').writeAsStringSync('coffee');
        Future<void> pump(bool Function() done) async {
          final end = DateTime.now().add(const Duration(seconds: 30));
          while (!done()) {
            if (DateTime.now().isAfter(end)) {
              fail('not reached: ${cloud.files.keys.toList()}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await engine.tick();
          }
        }

        await engine.tick();
        await pump(
          () =>
              cloud.files.containsKey('Docs/Report.txt') &&
              cloud.files.containsKey('Docs/$nfc'),
        );
        final verifications = engine.fullVerifications;
        File('$root/Docs/Report.txt').renameSync('$root/Docs/report.txt');
        File('$root/Docs/$nfc').renameSync('$root/Docs/$nfd');
        // The boundary: the old spellings resolve, with their stored names.
        final caseOnly = fs.watchScan(
          null,
          engine.tree.fd,
          'Docs/Report.txt',
          false,
        );
        expect(caseOnly.items.single['stored'], 'Docs/report.txt');
        final form = fs.watchScan(null, engine.tree.fd, 'Docs/$nfc', false);
        expect(form.items.single['stored'], 'Docs/$nfd');
        // Case-only: one MOVE (decision #138 keeps #120's pairing). NFC/NFD:
        // one name in the cloud, so no request; the row takes the local
        // spelling (#138).
        final uploads = cloud.uploads;
        await pump(
          () =>
              cloud.files.containsKey('Docs/report.txt') &&
              !cloud.files.containsKey('Docs/Report.txt') &&
              engine.manifest.entries.containsKey('Docs/$nfd') &&
              !engine.manifest.entries.containsKey('Docs/$nfc'),
        );
        expect(
          cloud.files.containsKey('Docs/$nfc'),
          isTrue,
          reason: 'NFC kept',
        );
        expect(cloud.files.containsKey('Docs/$nfd'), isFalse);
        expect(cloud.uploads, uploads, reason: 'nothing uploaded again');
        expect(engine.fullVerifications, verifications, reason: 'by events');
      } finally {
        engine.close();
      }
    },
  );

  test('per-path sync cost: durable commits against grouped commits', () async {
    Future<double> perPath(String name, {required bool groupCommits}) async {
      final engine = await engineAt(name, groupCommits: groupCommits);
      try {
        await engine.tick();
        final root = engine.tree.root.path;
        Directory('$root/Sample').createSync();
        for (var i = 0; i < 200; i++) {
          File('$root/Sample/s$i.txt').writeAsStringSync('sample $i');
        }
        final cloud = engine.cloud as FakeCloud;
        final started = DateTime.now();
        var uploaded = 0;
        while (uploaded < 200 &&
            DateTime.now().difference(started) < const Duration(seconds: 60)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await engine.tick();
          uploaded = cloud.files.keys
              .where((k) => k.startsWith('Sample/'))
              .length;
        }
        final elapsed = DateTime.now().difference(started);
        expect(uploaded, 200);
        return elapsed.inMicroseconds / 1000 / uploaded;
      } finally {
        engine.close();
      }
    }

    final before = await perPath('durable', groupCommits: false);
    final after = await perPath('grouped', groupCommits: true);
    // ignore: avoid_print
    print(
      'SC-051 per-path sync cost on this Mac: durable commits '
      '${before.toStringAsFixed(1)} ms, grouped commits '
      '${after.toStringAsFixed(1)} ms',
    );
    // Planner ruling (PR #68): measured on the mac-test VM's virtual disk,
    // where a barrier costs nearly a full flush; real-hardware cost is not
    // measured. Grouped commits must beat durable-each commits in the same
    // run by a quarter, and the 88.9 ms per path measured before M2b.
    expect(after, lessThan(before * 0.75));
    expect(after, lessThan(88.9));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
