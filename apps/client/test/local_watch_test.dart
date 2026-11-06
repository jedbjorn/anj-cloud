import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';

/// Spec #15 acceptance: native local change detection. Counters come from
/// `SyncEngine.lastPass`, `SyncEngine.fullScans` and the watcher. Runs on
/// Linux (inotify, tool/check.sh) and on macOS (FSEvents, spec #31 M2:
/// tool/macos/check_macos.sh); tests of Linux-only mechanisms say so.
void main() {
  // inotify watch limits and the procfs mount table have no macOS form:
  // FSEvents watches by prefix, and mounts arrive as stream events
  // (test_macos/fsevents_watch_macos_test.dart).
  final linuxOnly = Platform.isLinux ? null : 'Linux only (inotify, procfs)';
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _CountingCloud cloud;
  late SyncEngine engine;
  late bool closed;
  const ext4 = 0xEF53;
  // Fixtures live on tmpfs; index tests model a trusted filesystem with
  // periodic writeback from fake sysctls (M = 90 s), as in
  // incremental_index_test.dart.
  RootTree trusted(RootTree value) {
    final vm = Directory('${fixture.path}/vm')..createSync(recursive: true);
    File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('3000\n');
    File('${vm.path}/dirty_writeback_centisecs').writeAsStringSync('1500\n');
    File('${vm.path}/laptop_mode').writeAsStringSync('0\n');
    return value
      ..debugFsMagic = ext4
      ..vmDirectory = vm.path;
  }

  LocalWatcher watcher() => engine.watcher! as LocalWatcher;
  Future<void> startWatching() async {
    // Before the start, so the FSEvents latency follows the quiet period.
    engine.watcherSettings = const WatcherSettings(
      quiet: Duration(milliseconds: 150),
      maxDelay: Duration(seconds: 2),
    );
    await engine.startWatching();
    expect(engine.watcher, isNotNull, reason: 'the platform watcher starts');
    watcher()
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
  }

  setUp(() async {
    closed = false;
    // Canonical: a macOS root may not sit under a symlink (/var).
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-watch-test-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = trusted(RootTree.setup(parent.path, 'watch', NativeRootFs()));
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = _CountingCloud();
    engine = SyncEngine(store, tree, cloud);
    await startWatching();
  });
  tearDown(() {
    if (!closed) engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  int scanned() => engine.lastPass!.filesHashedBy['scan'] ?? 0;
  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  /// Lets events arrive, then runs passes until [done] (or fails).
  Future<void> pump(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
    Duration step = const Duration(milliseconds: 100),
  }) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      await Future<void>.delayed(step);
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) fail('condition not reached');
    }
  }

  /// Passes until no queued work remains and the last pass changed nothing.
  Future<void> quiesce() async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      if (watcher().queued == 0 && engine.lastPass!.pathsVisited == 0) {
        return;
      }
    }
    fail('did not quiesce');
  }

  test('startup walk closes the race with a concurrent writer', () async {
    store.verifyTracking = false;
    // Enough directories that the initial walk takes measurable time.
    for (var d = 0; d < 150; d++) {
      tree.ensureDirectory('Documents/s$d');
      for (var f = 0; f < 5; f++) {
        local('Documents/s$d/seed$f.txt').writeAsStringSync('seed $d $f');
      }
    }
    final done = ReceivePort();
    final created = Completer<List<String>>();
    done.listen((message) => created.complete((message as List).cast()));
    await Isolate.spawn(_writer, [done.sendPort, tree.root.path, 150]);
    // The writer is running while the first pass walks and watches.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await engine.tick();
    expect(engine.lastPass!.localScan, 'full');
    final paths = await created.future;
    done.close();
    expect(paths.length, greaterThan(100));
    await pump(() => paths.every((p) => remote(p) == 'written $p'));
    // Nothing needed another full scan: events and the walk covered all.
    expect(engine.fullScans, 1);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // The proof here is a write through a hard link outside the root, which
  // inotify never reports. On macOS that write is not silent (FSEvents or
  // the per-pass rehash sees it), so the same flags are proven there by
  // audit counters instead (test_macos/fsevents_watch_macos_test.dart).
  final hardLinkSilent = Platform.isLinux
      ? null
      : 'a hard-link write outside the root is not silent on macOS; '
            'covered by audit counters in test_macos/';
  group('lost events lead to audits', skip: hardLinkSilent, () {
    late File outside;
    const path = 'Documents/linked.txt';
    setUp(() async {
      // A hard link outside the root: writes through it notify only the
      // outside directory, so the root's watches never see them.
      local(path).writeAsStringSync('version 1');
      outside = File('${fixture.path}/outside-link');
      await Process.run('ln', [local(path).path, outside.path]);
      await quiesce();
      expect(remote(path), 'version 1');
    });
    Future<void> silentEdit(String content) async {
      outside.writeAsStringSync(content, flush: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.tick();
      expect(remote(path), 'version 1', reason: 'the edit sent no event');
    }

    test('queue overflow runs a full audit and misses nothing', () async {
      await silentEdit('version 2');
      final before = engine.fullScans;
      watcher().debugOverflow();
      await pump(() => remote(path) == 'version 2');
      expect(watcher().overflows, 1);
      expect(engine.fullScans, before + 1);
    });

    test('a suspend (clock jump) runs a full audit', () async {
      await silentEdit('version 3');
      final before = engine.fullScans;
      watcher().debugClockJump(const Duration(seconds: 30));
      await pump(() => remote(path) == 'version 3');
      expect(watcher().suspends, 1);
      expect(engine.fullScans, before + 1);
    });

    test('the periodic stat audit runs between events', () async {
      await silentEdit('version 4');
      engine.statAuditInterval = Duration.zero;
      final before = engine.fullScans;
      await engine.tick();
      expect(engine.fullScans, before + 1);
      await engine.tick();
      expect(remote(path), 'version 4');
    });
  });

  test('a full queue collapses to a subtree audit, not a drop', () async {
    tree.ensureDirectory('Documents/many');
    await quiesce();
    watcher().queueBound = 3;
    for (var i = 0; i < 25; i++) {
      local('Documents/many/f$i.txt').writeAsStringSync('many $i');
    }
    final before = engine.fullScans;
    await pump(
      () => List.generate(
        25,
        (i) => remote('Documents/many/f$i.txt'),
      ).every((v) => v != null),
    );
    expect(watcher().collapses, greaterThan(0));
    expect(engine.fullScans, before, reason: 'a subtree, not the root');
    for (var i = 0; i < 25; i++) {
      expect(remote('Documents/many/f$i.txt'), 'many $i');
    }
  });

  test(
    'watch exhaustion audits the subtree on a timer with a note',
    skip: linuxOnly,
    () async {
      watcher().unwatchedInterval = const Duration(seconds: 2);
      tree.ensureDirectory('Documents/limited/deeper');
      local('Documents/limited/a.txt').writeAsStringSync('a 1');
      watcher().debugFailAdds('Documents/limited');
      await quiesce();
      expect(remote('Documents/limited/a.txt'), 'a 1');
      expect(watcher().exhausted, greaterThanOrEqualTo(2));
      expect(engine.message, contains('checked periodically'));
      expect(engine.message, contains('limit on watched folders'));
      // No watch on these directories: only the timer finds the changes.
      final started = DateTime.now();
      local('Documents/limited/a.txt').writeAsStringSync('a 2');
      local('Documents/limited/deeper/b.txt').writeAsStringSync('b 1');
      await pump(
        () =>
            remote('Documents/limited/a.txt') == 'a 2' &&
            remote('Documents/limited/deeper/b.txt') == 'b 1',
      );
      expect(
        DateTime.now().difference(started),
        greaterThan(const Duration(milliseconds: 500)),
      );
      // When watches become available again the note clears.
      watcher().debugFailAdds(null);
      await pump(() => watcher().unwatched == 0);
      await engine.tick();
      expect(engine.message, isNot(contains('checked periodically')));
    },
  );

  test(
    'an editor-style atomic save repeated 20 times in 2 s uploads once',
    () async {
      const path = 'Documents/doc.txt';
      local(path).writeAsStringSync('save 0');
      await quiesce();
      expect(cloud.uploadsOf(path), 1);
      // Production quiet period and maximum delay.
      watcher()
        ..quiet = const Duration(milliseconds: 1500)
        ..maxDelay = const Duration(seconds: 10);
      final input = StreamController<Object?>();
      final loop = WorkerLoop(engine, (_) {});
      final running = loop.run(input.stream);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (var i = 1; i <= 20; i++) {
        final temporary = local('Documents/.doc.txt.tmp$i')
          ..writeAsStringSync('save $i', flush: true);
        temporary.renameSync(local(path).path);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (remote(path) != 'save 20' && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      input.add({'action': 'stop'});
      await running.timeout(const Duration(seconds: 20));
      closed = true;
      await input.close();
      expect(remote(path), 'save 20');
      expect(cloud.uploadsOf(path), 2, reason: 'initial upload plus one');
      expect(
        cloud.files.keys.where((k) => k.contains('.tmp')),
        isEmpty,
        reason: 'temporary files settled away before their quiet period ended',
      );
    },
  );

  // macOS: every upload pays a manifest commit with F_FULLFSYNC (about 89 ms
  // per path on mac-test, PR #62; batching is flag SC-051), so 2,000 paths
  // take about 3 minutes there. Longer limits only, as decision #129 rules.
  final macCommitCost = Platform.isMacOS;
  test('a 2k-file tree moved into the root is queued and uploaded', () async {
    store.verifyTracking = false;
    await quiesce();
    final staging = Directory('${fixture.path}/incoming/tree')
      ..createSync(recursive: true);
    for (var d = 0; d < 20; d++) {
      final dir = Directory('${staging.path}/d$d/inner')
        ..createSync(recursive: true);
      for (var f = 0; f < 100; f++) {
        File('${dir.path}/f$f.txt').writeAsStringSync('tree $d $f');
      }
    }
    final scans = engine.fullScans;
    staging.renameSync(local('Documents/tree').path);
    await pump(
      () =>
          cloud.files.keys
              .where((k) => k.startsWith('Documents/tree/'))
              .length ==
          2000,
      timeout: Duration(minutes: macCommitCost ? 6 : 2),
    );
    expect(remote('Documents/tree/d7/inner/f42.txt'), 'tree 7 42');
    expect(engine.fullScans, scans, reason: 'found by events, not an audit');
    // The moved tree is watched: a later edit deep inside is an event.
    await quiesce();
    local('Documents/tree/d3/inner/f5.txt').writeAsStringSync('edited');
    await pump(() => remote('Documents/tree/d3/inner/f5.txt') == 'edited');
    expect(engine.fullScans, scans);
  }, timeout: Timeout(Duration(minutes: macCommitCost ? 8 : 3)));

  test('a directory rename is one cloud move with watches remapped', () async {
    tree.ensureDirectory('Documents/old/sub');
    local('Documents/old/sub/x.txt').writeAsStringSync('x');
    await quiesce();
    final uploads = cloud.uploads;
    Directory(local('Documents/old').path)
        .renameSync(local('Documents/new').path);
    await pump(() => remote('Documents/new/sub/x.txt') == 'x');
    // Paired by identity (spec #33 I1): the folder moves, nothing is
    // deleted or uploaded again.
    expect(cloud.moves, ['Documents/old -> Documents/new']);
    expect(cloud.uploads, uploads);
    expect(cloud.deletes, 0);
    expect(store.operations.values.where((o) => o.kind == 'delete'), isEmpty);
    local('Documents/new/sub/x.txt').writeAsStringSync('x2');
    await pump(() => remote('Documents/new/sub/x.txt') == 'x2');
    expect(engine.fullScans, 1);
  });

  test("the client's own downloads and staging moves stay quiet", () async {
    tree.debugConfirmMicros =
        600000000; // Keep confirmation hashes out of view.
    // Multigrain ctime (The VM host's kernel); the coarse case is tested below.
    tree.debugFineCtime = true;
    local('Documents/kept.txt').writeAsStringSync('kept');
    local('Documents/gone.txt').writeAsStringSync('gone');
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await quiesce();
    final uploads = cloud.uploads;
    // Downloads (new files, a new folder, a replacement) and a remote
    // deletion that moves the local file into staging.
    for (var i = 0; i < 10; i++) {
      cloud.put('Documents/remote$i.txt', 'remote $i');
    }
    cloud.directories.add('Music/new');
    cloud.versions['Music/new'] = '"dir-new"';
    cloud.put('Music/new/inside.txt', 'inside');
    cloud.put('Documents/kept.txt', 'kept from cloud');
    cloud.remove('Documents/gone.txt');
    await engine.tick();
    expect(engine.lastPass!.filesHashedBy['download'], greaterThan(0));
    expect(local('Documents/remote3.txt').readAsStringSync(), 'remote 3');
    expect(local('Documents/kept.txt').readAsStringSync(), 'kept from cloud');
    expect(local('Documents/gone.txt').existsSync(), isFalse);
    // Every event caused by those operations arrives and settles.
    final events = watcher().events;
    var hashed = 0;
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      hashed += scanned();
    }
    expect(watcher().events, greaterThan(events), reason: 'events arrived');
    expect(watcher().queued, 0);
    expect(hashed, 0, reason: 'no rehash caused by own events');
    expect(cloud.uploads, uploads, reason: 'no upload caused by own events');
    expect(engine.lastPass!.pathsVisited, 0);
  });

  test(
    'idle: no full scans or local reads between audits; the watcher sleeps',
    () async {
      store.verifyTracking = false;
      tree.debugConfirmMicros = 1000000;
      for (var i = 0; i < 200; i++) {
        tree.ensureDirectory('Documents/i${i ~/ 20}');
        local('Documents/i${i ~/ 20}/f$i.txt').writeAsStringSync('idle $i');
      }
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await quiesce();
      // Let every confirmation hash fall due and run.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await engine.tick();
      await engine.tick();
      expect(
        store.entries.values
            .where((e) => e.kind == ItemKind.file)
            .every((e) => e.stampFinal),
        isTrue,
      );
      final events = watcher().events;
      final scans = engine.fullScans;
      // As many passes as 10 idle minutes at the production 2 s interval.
      for (var i = 0; i < 300; i++) {
        await engine.tick();
        final last = engine.lastPass!;
        expect(last.localScan, 'partial');
        expect(last.pathsStatted, 0);
        expect(last.filesHashed, 0);
        expect(last.rowsWritten, 0);
        if (i % 50 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      expect(engine.fullScans, scans, reason: '0 full stat scans');
      expect(
        watcher().events,
        events,
        reason: 'the watcher isolate slept in poll',
      );
      // Nothing local is due before the 5-minute stat audit (decision #51).
      expect(
        engine.nextLocalDeadline()!,
        greaterThan(const Duration(minutes: 4)),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('offline idle passes stat nothing either', () async {
    cloud.online = false;
    for (var i = 0; i < 50; i++) {
      local('Documents/o$i.txt').writeAsStringSync('offline $i');
    }
    await engine.tick();
    expect(engine.lastPass!.localScan, 'full');
    expect(engine.message, startsWith('Offline'));
    for (var i = 0; i < 5; i++) {
      await engine.tick();
      expect(engine.lastPass!.localScan, 'partial');
      expect(engine.lastPass!.pathsStatted, 0);
    }
    // Back online, everything still reconciles from the kept view.
    cloud.online = true;
    await pump(() => remote('Documents/o49.txt') == 'offline 49');
  });

  test(
    'the confirmation hash after M still runs without a full scan',
    () async {
      tree.debugConfirmMicros = 3000000;
      const path = 'Documents/confirm.txt';
      local(path).writeAsStringSync('confirm me');
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await quiesce();
      expect(store.entries[path]!.stampFinal, isFalse);
      final scans = engine.fullScans;
      // Idle: the confirmation is scheduled from the index, not by an event.
      final due = engine.nextLocalDeadline();
      expect(due, isNotNull);
      expect(due!, lessThanOrEqualTo(const Duration(seconds: 3)));
      var confirmations = 0;
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
        confirmations += scanned();
      }
      expect(confirmations, 1, reason: 'exactly one confirmation hash');
      expect(store.entries[path]!.stampFinal, isTrue);
      expect(engine.fullScans, scans);
    },
  );

  test(
    'a forward wall-clock step does not finalize before M monotonic (#39)',
    () async {
      tree.debugConfirmMicros = 3000000;
      const path = 'Documents/step.txt';
      local(path).writeAsStringSync('step');
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await quiesce();
      final observed = DateTime.now();
      expect(store.entries[path]!.stampFinal, isFalse);
      // NTP-style forward step: the ctime now looks hours old.
      final real = tree.wallMicros;
      tree.wallMicros = () => real() + const Duration(hours: 2).inMicroseconds;
      var confirmations = 0;
      while (DateTime.now().difference(observed) <
          const Duration(milliseconds: 1500)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
        confirmations += scanned();
        expect(store.entries[path]!.stampFinal, isFalse);
      }
      final end = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
        confirmations += scanned();
      }
      expect(confirmations, 1);
      expect(store.entries[path]!.stampFinal, isTrue);
      expect(engine.fullScans, 1);
    },
  );

  test(
    'a shared-mmap write (no event) is uploaded by the confirmation hash',
    () async {
      final disk = Directory('.dart_tool/anj-disk-fixtures')
        ..createSync(recursive: true);
      final base = disk.createTempSync('watch-mmap-');
      final parent = Directory('${base.path}/files')..createSync();
      final diskTree = RootTree.setup(parent.path, 'disk', NativeRootFs());
      final diskStore = Manifest(Directory('${base.path}/profile'))
        ..setSetting('retention', 'local');
      final diskCloud = FakeCloud();
      final diskEngine = SyncEngine(diskStore, diskTree, diskCloud);
      Process? writer;
      try {
        final magic = diskTree.native.fsMagic(diskTree.fd, '');
        diskTree.refreshWriteback();
        if (!NativeRootFs.trustedMagic.contains(magic) ||
            !diskTree.writebackEnabled) {
          markTestSkipped('needs a trusted disk filesystem with writeback');
          return;
        }
        await diskEngine.startWatching();
        (diskEngine.watcher! as LocalWatcher).quiet = const Duration(
          milliseconds: 150,
        );
        diskTree.debugConfirmMicros = 4000000;
        const path = 'Documents/db.bin';
        final file = File('${diskTree.root.path}/$path')
          ..writeAsStringSync('mmap-0000');
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
        Future<void> passes(Duration span) async {
          final end = DateTime.now().add(span);
          while (DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            await diskEngine.tick();
          }
        }

        await passes(const Duration(milliseconds: 2500));
        expect(String.fromCharCodes(diskCloud.files[path]!), 'Amap-0000');
        expect(diskStore.entries[path]!.stampFinal, isFalse);
        final events = (diskEngine.watcher! as LocalWatcher).events;
        // Same still-dirty page: no mtime/ctime change and no inotify event.
        await write(1, 'B');
        await passes(const Duration(milliseconds: 600));
        expect(String.fromCharCodes(diskCloud.files[path]!), 'Amap-0000');
        expect(
          (diskEngine.watcher! as LocalWatcher).events,
          events,
          reason: 'mmap writes are silent',
        );
        await passes(const Duration(seconds: 5));
        expect(String.fromCharCodes(diskCloud.files[path]!), 'ABap-0000');
        expect(
          diskEngine.fullScans,
          1,
          reason: 'found by the scheduled confirmation',
        );
      } finally {
        writer?.kill();
        await writer?.exitCode;
        diskEngine.close();
        base.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'root moved away pauses; moved back resumes with a full audit',
    () async {
      local('Documents/r.txt').writeAsStringSync('r');
      await quiesce();
      final away = Directory('${fixture.path}/files/away');
      tree.root.renameSync(away.path);
      await pump(() => engine.message.startsWith('Paused'));
      expect(watcher().rootEvents, greaterThan(0));
      away.renameSync(tree.root.path);
      final scans = engine.fullScans;
      await pump(() => engine.message.startsWith('Reconciled'));
      expect(engine.fullScans, scans + 1);
      local('Documents/r.txt').writeAsStringSync('r2');
      await pump(() => remote('Documents/r.txt') == 'r2');
    },
  );

  test('without inotify the per-pass stat scan stays, with a note', () async {
    local('Documents/f.txt').writeAsStringSync('f1');
    await quiesce();
    watcher().failure = 'injected';
    final scans = engine.fullScans;
    await engine.tick();
    expect(engine.lastPass!.localScan, 'full');
    expect(engine.message, contains('Folder watching is unavailable'));
    local('Documents/f.txt').writeAsStringSync('f2');
    await engine.tick();
    expect(remote('Documents/f.txt'), 'f2');
    expect(engine.fullScans, scans + 2);
  });

  test('with coarse ctimes an own install is read once (racy rule)', () async {
    tree.debugConfirmMicros = 600000000;
    tree.debugFineCtime = false;
    await quiesce();
    cloud.put('Documents/coarse.txt', 'from cloud');
    await engine.tick();
    expect(local('Documents/coarse.txt').readAsStringSync(), 'from cloud');
    var hashed = 0;
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      hashed += scanned();
    }
    expect(hashed, greaterThanOrEqualTo(1), reason: 'the stamp is not trusted');
    expect(cloud.uploadsOf('Documents/coarse.txt'), 0);
  });

  test('the ctime probe answers without touching the root', () {
    final before = Directory(tree.root.path).listSync(recursive: true).length;
    expect(tree.fineCtime, isA<bool>());
    expect(Directory(tree.root.path).listSync(recursive: true).length, before);
    expect(
      tree.staging.listSync().where((f) => f.path.contains('ctime-probe')),
      isEmpty,
    );
  });

  test(
    'a dead watcher is noted, audited at once and restarted (bounded)',
    () async {
      local('Documents/w.txt').writeAsStringSync('w1');
      await quiesce();
      engine.watchRestartDelay = const Duration(seconds: 1);
      engine.watchRestartLimit = 1;
      final first = watcher();
      final scans = engine.fullScans;
      first.debugKill();
      // Wait for the death without running passes.
      for (var i = 0; first.active && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(first.active, isFalse);
      expect(first.failure, isNotNull);
      expect(engine.nextLocalDeadline(), Duration.zero, reason: 'audit now');
      await engine.tick();
      expect(engine.lastPass!.localScan, 'full');
      expect(engine.fullScans, scans + 1);
      expect(engine.message, contains('Folder watching is unavailable'));
      // Restarted after the delay; events flow again and the note clears.
      await pump(() => engine.watcher != first && engine.watcher!.active);
      expect(engine.watchRestarts, 1);
      await quiesce();
      expect(engine.message, isNot(contains('unavailable')));
      final events = watcher().events;
      local('Documents/w.txt').writeAsStringSync('w2');
      await pump(() => remote('Documents/w.txt') == 'w2');
      expect(watcher().events, greaterThan(events));
      // The restart budget is spent: a second death stays on the per-pass scan.
      final second = watcher();
      second.debugKill();
      // Wait for the death without running passes.
      for (var i = 0; second.active && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(second.active, isFalse);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await engine.tick();
      }
      expect(engine.watcher, same(second));
      expect(second.closed, isTrue, reason: 'its watches are released');
      expect(engine.lastPass!.localScan, 'full');
      expect(engine.message, contains('Folder watching is unavailable'));
      local('Documents/w.txt').writeAsStringSync('w3');
      await engine.tick();
      expect(remote('Documents/w.txt'), 'w3');
    },
  );

  test(
    'a backlog the busy worker cannot take collapses to one audit',
    () async {
      store.verifyTracking = false;
      await quiesce();
      watcher().close();
      final small = await LocalWatcher.start(
        tree.native as NativeRootFs,
        tree.fd,
        tree.root.path,
        inFlight: 1,
        backlogBound: 10,
      );
      engine.attachWatcher(small!);
      small
        ..quiet = const Duration(milliseconds: 150)
        ..maxDelay = const Duration(seconds: 2);
      await engine.tick();
      final scans = engine.fullScans;
      tree.ensureDirectory('Documents/burst');
      await quiesce();
      final writer = await Process.start('python3', [
        '-I',
        '-c',
        'import sys,time\n'
            'for i in range(300):\n'
            ' open(sys.argv[1]+"/b%d.txt"%i,"w").write("burst %d"%i)\n'
            ' time.sleep(0.002)\n',
        local('Documents/burst').path,
      ]);
      // The worker is busy (blocked) while the events arrive.
      sleep(const Duration(seconds: 3));
      expect(await writer.exitCode, 0);
      await pump(
        () => List.generate(
          300,
          (i) => remote('Documents/burst/b$i.txt'),
        ).every((v) => v != null),
      );
      expect(small.backlogOverflows, greaterThan(0));
      expect(engine.fullScans, greaterThan(scans));
    },
  );

  test(
    'with the root moved away passes keep the base interval, then resume',
    () async {
      // Review of a625628: a failing local scan left an audit due at once,
      // so the loop retried at its 250 ms minimum gap. Real timers: the
      // watcher isolate and the engine's monotonic clock cannot run on a
      // fake clock. A 1 s base interval keeps the window short.
      const interval = Duration(seconds: 1);
      final base = Directory('${fixture.path}/cadence')..createSync();
      final parent = Directory('${base.path}/files')..createSync();
      final cadenceTree = RootTree.setup(parent.path, 'r', NativeRootFs());
      final cadenceStore = Manifest(Directory('${base.path}/profile'))
        ..setSetting('retention', 'local');
      final cadenceCloud = FakeCloud();
      final cadence = _PassTimes(cadenceStore, cadenceTree, cadenceCloud);
      await cadence.startWatching();
      expect(cadence.watcher, isNotNull);
      final input = StreamController<Object?>();
      final loop = WorkerLoop(cadence, (_) {}, interval: interval);
      final running = loop.run(input.stream);
      try {
        cadenceTree.ensureDirectory('Documents');
        File('${cadenceTree.root.path}/Documents/a.txt')
            .writeAsStringSync('a1');
        for (var i = 0; i < 100 && cadenceCloud.files.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(cadenceCloud.files, contains('Documents/a.txt'));
        final rootPath = cadenceTree.root.path;
        final moved = '${base.path}/moved';
        Directory(rootPath).renameSync(moved);
        // Let the first failing pass run, then count over a fixed window.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(cadence.localUnavailable, isTrue);
        expect(cadence.message, contains('unavailable'));
        expect(
          cadence.nextLocalDeadline(),
          isNull,
          reason: 'a failed scan never brings the next pass forward',
        );
        final from = cadence.starts.length;
        const window = Duration(seconds: 5);
        await Future<void>.delayed(window);
        final starts = cadence.starts.sublist(from);
        final gaps = [
          for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1],
        ];
        // ignore: avoid_print
        print(
          'root gone: ${starts.length} passes in ${window.inSeconds} s, '
          'gaps ${gaps.map((g) => g.inMilliseconds).join(', ')} ms',
        );
        expect(starts.length, lessThanOrEqualTo(window.inSeconds + 1));
        for (final gap in gaps) {
          expect(
            gap,
            greaterThanOrEqualTo(interval - const Duration(milliseconds: 20)),
          );
        }
        // The folder returns: the next pass audits it and uploads the edit.
        File('$moved/Documents/a.txt').writeAsStringSync('a2');
        Directory(moved).renameSync(rootPath);
        final back = DateTime.now();
        while (String.fromCharCodes(cadenceCloud.files['Documents/a.txt']!) !=
                'a2' &&
            DateTime.now().difference(back) < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          String.fromCharCodes(cadenceCloud.files['Documents/a.txt']!),
          'a2',
        );
        expect(
          DateTime.now().difference(back),
          lessThan(interval * 3),
          reason: 'resumed within the base interval',
        );
        expect(cadence.localUnavailable, isFalse);
      } finally {
        input.add({'action': 'stop'});
        await running.timeout(const Duration(seconds: 20));
        await input.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a mount-table change beneath the root audits that subtree',
    skip: linuxOnly,
    () async {
      tree.ensureDirectory('Documents/mnt');
      local('Documents/mnt/m.txt').writeAsStringSync('m1');
      final outside = File('${fixture.path}/mnt-link');
      await quiesce();
      await Process.run('ln', [
        local('Documents/mnt/m.txt').path,
        outside.path,
      ]);
      await quiesce();
      outside.writeAsStringSync('m2', flush: true); // No event: a "mount".
      final table = File('${fixture.path}/mountinfo')
        ..writeAsStringSync(
          '36 35 98:0 / ${tree.root.path}/Documents/mnt rw - ext4 /dev/x rw\n',
        );
      final saved = LocalWatcher.mountInfoPath;
      LocalWatcher.mountInfoPath = table.path;
      try {
        final scans = engine.fullScans;
        watcher().debugMountsChanged();
        await pump(() => remote('Documents/mnt/m.txt') == 'm2');
        expect(watcher().mountChanges, 1);
        expect(engine.fullScans, scans, reason: 'only the mounted subtree');
      } finally {
        LocalWatcher.mountInfoPath = saved;
      }
    },
  );

  test('mount points match a root configured through a symlink', skip: linuxOnly, () async {
    await quiesce();
    watcher().close();
    final link = Link('${fixture.path}/link')
      ..createSync('${fixture.path}/files');
    final configured = '${link.path}/${tree.root.path.split('/').last}';
    final viaLink = await LocalWatcher.start(
      tree.native as NativeRootFs,
      tree.fd,
      configured,
    );
    engine.attachWatcher(viaLink!);
    // The mount table spells the canonical path, not the configured one.
    final table = File('${fixture.path}/mountinfo')
      ..writeAsStringSync(
        '36 35 98:0 / ${tree.root.resolveSymbolicLinksSync()}/Documents/mnt rw - ext4 /dev/x rw\n',
      );
    final saved = LocalWatcher.mountInfoPath;
    LocalWatcher.mountInfoPath = table.path;
    try {
      viaLink.debugMountsChanged();
      for (var i = 0; viaLink.mountChanges == 0 && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(viaLink.mountChanges, 1, reason: 'Documents/mnt is audited');
    } finally {
      LocalWatcher.mountInfoPath = saved;
    }
  });

  test(
    'a shared-mmap write to a confirmed file is found by the 5-minute audit',
    () async {
      // Decision #51. Real writeback needs a real disk; .dart_tool is ignored.
      final disk = Directory('.dart_tool/anj-disk-fixtures')
        ..createSync(recursive: true);
      final base = disk.createTempSync('watch-final-');
      final parent = Directory('${base.path}/files')..createSync();
      final diskTree = RootTree.setup(parent.path, 'disk', NativeRootFs());
      final diskStore = Manifest(Directory('${base.path}/profile'))
        ..setSetting('retention', 'local');
      final diskCloud = FakeCloud();
      final diskEngine = SyncEngine(diskStore, diskTree, diskCloud);
      Process? writer;
      try {
        diskTree.refreshWriteback();
        if (!NativeRootFs.trustedMagic.contains(
              diskTree.native.fsMagic(diskTree.fd, ''),
            ) ||
            !diskTree.writebackEnabled) {
          markTestSkipped('needs a trusted disk filesystem with writeback');
          return;
        }
        expect(diskEngine.statAuditInterval, const Duration(minutes: 5));
        await diskEngine.startWatching();
        (diskEngine.watcher! as LocalWatcher).quiet = const Duration(
          milliseconds: 150,
        );
        diskTree.debugConfirmMicros = 2000000;
        const path = 'Documents/final.bin';
        final file = File('${diskTree.root.path}/$path')
          ..writeAsStringSync('mmap-0000');
        Future<void> passes(Duration span) async {
          final end = DateTime.now().add(span);
          while (DateTime.now().isBefore(end)) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            await diskEngine.tick();
          }
        }

        writer = await Process.start('python3', [
          '-I',
          '-c',
          'import mmap,os,sys\n'
              'fd=os.open(sys.argv[1],os.O_RDWR)\n'
              'm=mmap.mmap(fd,0)\n'
              'os.close(fd)\n'
              'print("ready",flush=True)\n'
              'for line in sys.stdin:\n'
              ' m[0]=ord(line.strip());print("ok",flush=True)\n',
          file.path,
        ]);
        final lines = writer.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();
        expect(await lines.first, 'ready');
        // Uploaded, then confirmed (final) after M on both clocks.
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (!(diskStore.entries[path]?.stampFinal ?? false) &&
            DateTime.now().isBefore(end)) {
          await passes(const Duration(milliseconds: 400));
        }
        expect(diskStore.entries[path]!.stampFinal, isTrue);
        expect(String.fromCharCodes(diskCloud.files[path]!), 'mmap-0000');
        await Process.run('sync', [file.path]);
        await passes(const Duration(milliseconds: 600));
        final events = (diskEngine.watcher! as LocalWatcher).events;
        final scans = diskEngine.fullScans;
        final ack = lines.first;
        writer.stdin.writeln('Z');
        await writer.stdin.flush();
        expect(await ack, 'ok');
        await passes(const Duration(seconds: 2));
        expect(
          (diskEngine.watcher! as LocalWatcher).events,
          events,
          reason: 'no inotify event',
        );
        expect(String.fromCharCodes(diskCloud.files[path]!), 'mmap-0000');
        // The audit interval is 5 minutes in the product; shortened here.
        diskEngine.statAuditInterval = const Duration(seconds: 1);
        await passes(const Duration(seconds: 2));
        expect(String.fromCharCodes(diskCloud.files[path]!), 'Zmap-0000');
        expect(diskEngine.fullScans, greaterThan(scans));
      } finally {
        writer?.kill();
        await writer?.exitCode;
        diskEngine.close();
        base.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('queue', () {
    late int now;
    setUp(() {
      now = 0;
      watcher().debugNow = () => now;
      watcher()
        ..quiet = const Duration(milliseconds: 1500)
        ..maxDelay = const Duration(seconds: 10);
    });
    test('a path matures after its quiet period or the maximum delay', () {
      watcher().enqueue('Documents/a.txt');
      now = 1000000;
      expect(watcher().take().paths, isEmpty);
      // Repeated events keep it quiet-pending, up to the maximum delay.
      for (now = 1000000; now < 10000000; now += 1000000) {
        watcher().enqueue('Documents/a.txt');
        expect(watcher().take().paths, isEmpty);
      }
      now = 10000000;
      expect(watcher().take().paths, {'Documents/a.txt'});
      watcher().enqueue('Documents/b.txt');
      now += 1500000;
      expect(watcher().take().paths, {'Documents/b.txt'});
    });
    test('a subtree marker absorbs events beneath it', () {
      watcher().enqueue('Documents/t', subtree: true);
      watcher().enqueue('Documents/t/x/y.txt');
      expect(watcher().queued, 1);
      now = 2000000;
      final work = watcher().take();
      expect(work.subtrees, {'Documents/t'});
      expect(work.paths, isEmpty);
    });
    test('the bound collapses to the common ancestor', () {
      watcher().queueBound = 2;
      watcher().enqueue('Documents/p/q/a.txt');
      watcher().enqueue('Documents/p/q/b.txt');
      watcher().enqueue('Documents/p/r/c.txt');
      expect(watcher().collapses, 1);
      now = 2000000;
      expect(watcher().take().subtrees, {'Documents/p'});
      watcher().enqueue('Documents/a.txt');
      watcher().enqueue('Music/b.txt');
      watcher().enqueue('Videos/c.txt');
      expect(watcher().fullAuditWanted, isTrue, reason: 'common is the root');
    });
  });
}

/// Creates files (and new directories) while the first pass walks the root.
Future<void> _writer(List<Object?> args) async {
  final port = args[0] as SendPort;
  final root = args[1] as String;
  final count = args[2] as int;
  final created = <String>[];
  for (var i = 0; i < count; i++) {
    final path = i % 3 == 0
        ? 'Documents/new$i/w$i.txt'
        : 'Documents/s${(i * 7) % 150}/w$i.txt';
    final file = File('$root/$path');
    file.parent.createSync();
    file.writeAsStringSync('written $path');
    created.add(path);
    if (i % 10 == 0) await Future<void>.delayed(Duration.zero);
  }
  port.send(created);
}

class _CountingCloud extends FakeCloud {
  final Map<String, int> _uploads = {};
  int uploadsOf(String path) => _uploads[path] ?? 0;
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    _uploads[path] = uploadsOf(path) + 1;
    return super.upload(path, source, etag: etag);
  }
}

/// Records when each pass starts (monotonic).
class _PassTimes extends SyncEngine {
  _PassTimes(super.manifest, super.tree, super.cloud);
  final Stopwatch _since = Stopwatch()..start();
  final List<Duration> starts = [];
  @override
  Future<void> tick({
    Future<bool> Function()? between,
    RemotePolicy remote = RemotePolicy.always,
  }) {
    starts.add(_since.elapsed);
    return super.tick(between: between, remote: remote);
  }
}
