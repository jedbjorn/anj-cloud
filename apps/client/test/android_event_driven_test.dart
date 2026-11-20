// Decision #130 (3) and (4), spec #28 A2: what Android adds to the shared
// event-driven hashing of event_driven_hashing_test.dart (decision #135):
// its 15-minute adapter, the watch-limit verification, the verification when
// the app opens (and only there) and the interrupted-install leftover. Runs on
// Linux with the Android adapters over the Linux build of the same anj_* ABI;
// the on-device run is integration_test/android_engine_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/phone_folders.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/artifacts.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _ListedCloud extends FakeCloud {
  int listings = 0;

  @override
  Future<List<RemoteItem>> snapshot() {
    listings++;
    return super.snapshot();
  }
}

/// Android's filesystem adapter with a short verification interval.
class _ShortVerification extends AndroidRootFs {
  _ShortVerification(this.interval)
    : super(Platform.environment['ANJ_ROOTFS_LIBRARY']);
  Duration interval;
  void Function()? beforeScanHash;
  @override
  Duration? get fullVerificationInterval => interval;

  @override
  ({String hash, String stamp}) copyAndHashStamped(
    int root,
    String relative,
    File? destination, {
    String purpose = 'content',
  }) {
    if (purpose == 'scan') beforeScanHash?.call();
    return super.copyAndHashStamped(
      root,
      relative,
      destination,
      purpose: purpose,
    );
  }
}

class _ForegroundFixture implements ForegroundReads {
  _ForegroundFixture(this.cloud, {this.beforeRoot, this.beforeFile});
  final FakeCloud cloud;
  final Future<void> Function()? beforeRoot;
  final Future<void> Function()? beforeFile;

  @override
  Future<void> checkRoot({
    required bool Function() stillWanted,
    required Future<void>? Function() selectedRead,
  }) async {
    await beforeRoot?.call();
    cloud.check();
  }

  @override
  Future<RemoteItem> checkFile(String path, String etag) async {
    await beforeFile?.call();
    return RemoteItem(path, ItemKind.file, cloud.versions[path]!);
  }

  @override
  void clearCheckedRoot() {}

  @override
  void guardListing({
    required bool Function() stillWanted,
    required Future<void>? Function() selectedRead,
  }) {}
}

class _SlowPhoneEnumeration extends AndroidPhoneRootFs {
  _SlowPhoneEnumeration(super.layout);

  final enumerating = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<RootScan> enumerateInIsolate(
    int root,
    String path, {
    required bool watched,
    Pointer<Void>? watch,
  }) async {
    if (path == 'Movies' && !enumerating.isCompleted) {
      // The private root and Music have been read. Hold enumeration of
      // Movies before any of the library's content is hashed.
      enumerating.complete();
      await resume.future;
    }
    return super.enumerateInIsolate(root, path, watched: watched, watch: watch);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late _ListedCloud cloud;
  late SyncEngine engine;
  late _ShortVerification fs;
  var closed = false;

  File local(String path) => File('${tree.root.path}/$path');
  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  LocalWatcher watcher() => engine.watcher! as LocalWatcher;
  const wait = Duration(seconds: 10);

  void addCloudOnly(String selected) {
    cloud.put(selected, 'selected file');
    store.entries[selected] = Entry(selected, ItemKind.file)
      ..etag = cloud.versions[selected]
      ..override = Retention.cloud
      ..status = 'cloud-only';
    store.save();
  }

  Future<void> pump(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) fail('condition not reached');
    }
  }

  /// Ticks until the watcher holds nothing and a pass hashes nothing.
  Future<void> quiesce() async {
    var calm = 0;
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      calm = watcher().queued == 0 && engine.lastPass!.filesHashed == 0
          ? calm + 1
          : 0;
      if (calm >= 4) return;
    }
    fail('did not quiesce');
  }

  Future<SyncEngine> open(SyncEngine Function() create) async {
    final value = create();
    await value.startWatching();
    expect(value.watcher, isNotNull);
    (value.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
    return value;
  }

  setUp(() async {
    closed = false;
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-android-hash-')
          .resolveSymbolicLinksSync(),
    );
    fs = _ShortVerification(const Duration(minutes: 15));
    tree = RootTree.setup(fixture.path, 'events', fs);
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = _ListedCloud();
    for (var i = 0; i < 20; i++) {
      local('Documents/f$i.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $i');
    }
    engine = await open(
      () => SyncEngine(
        store,
        tree,
        cloud,
        watchers: const AndroidChangeWatchers(),
      ),
    );
  });

  tearDown(() {
    if (!closed) engine.close();
    fixture.deleteSync(recursive: true);
  });

  test(
    'the first pass verifies every file, idle passes hash nothing',
    () async {
      await engine.tick();
      expect(engine.eventDriven, isTrue);
      expect(engine.fullVerifications, 1);
      expect(engine.lastPass!.filesHashedBy['scan'], 20);
      await quiesce();
      for (var i = 0; i < 3; i++) {
        await engine.tick();
        expect(engine.lastPass!.filesHashed, 0);
        expect(engine.lastPass!.localScan, 'partial');
      }
      expect(engine.fullVerifications, 1);
      expect(cloud.uploads, 20);
    },
  );

  test(
    'connects before the first audit and opens between audit reads',
    () async {
      const selected = 'read-first.txt';
      addCloudOnly(selected);

      final input = StreamController<Object?>();
      final opened = Completer<String>();
      final settled = Completer<void>();
      var hashesAtConnect = -1;
      var hashesAtOpen = -1;
      var scanReads = 0;
      final reads = _ForegroundFixture(cloud);
      final loop = WorkerLoop(engine, (event) {
        final value = event as Map;
        if (value['status'] == SyncStatus.checkingChanges.name &&
            hashesAtConnect == -1) {
          hashesAtConnect = scanReads;
        }
        if (value['event'] == 'open') {
          hashesAtOpen = scanReads;
          opened.complete(File(value['path'] as String).readAsStringSync());
        }
        if (value['status'] == SyncStatus.upToDate.name &&
            !settled.isCompleted) {
          settled.complete();
        }
      }, foregroundReads: () => reads);
      fs.beforeScanHash = () {
        if (++scanReads != 1) return;
        input
          ..add({'action': 'visible', 'verify': true})
          ..add({'action': 'open', 'path': selected, 'providerTracked': true});
        // One deliberately slow descriptor-bound read, to exercise the
        // checkpoint while the nineteen other audit reads are still pending.
        sleep(const Duration(milliseconds: 20));
      };
      final done = loop.run(input.stream);
      try {
        expect(
          await opened.future.timeout(const Duration(seconds: 5)),
          'selected file',
        );
        await settled.future.timeout(const Duration(seconds: 5));
        expect(hashesAtConnect, 0);
        expect(hashesAtOpen, inInclusiveRange(1, 19));
        expect(engine.fullVerifications, 1);
        expect(engine.lastPass!.filesHashedBy['scan'], 20);
      } finally {
        input.add({'action': 'stop'});
        await done;
        await input.close();
        closed = true;
      }
    },
  );

  for (final watched in [true, false]) {
    test(
      'opens while mapped directory enumeration waits (watched: $watched)',
      () async {
        engine.close();
        closed = true;
        final base = Directory('${fixture.path}/phone')..createSync();
        for (final name in phoneFolderNames.values) {
          Directory('${base.path}/$name').createSync();
        }
        File('${base.path}/Movies/a.txt').writeAsStringSync('in Movies');
        final phoneFs = _SlowPhoneEnumeration(
          PhoneFolderLayout(
            base: base.path,
            staging: '${base.path}/staging',
            paused: false,
          ),
        );
        tree = RootTree(tree.root, tree.staging, phoneFs);
        store = Manifest(Directory('${fixture.path}/profile'));
        Directory('${tree.root.path}/Unrelated').createSync();
        const selected = 'read-first.txt';
        addCloudOnly(selected);
        engine = SyncEngine(
          store,
          tree,
          cloud,
          watchers: watched
              ? const AndroidChangeWatchers()
              : const UnwatchedChangeWatchers(),
        );
        await engine.startWatching();
        final w = engine.watcher as LocalWatcher?;
        expect(w != null, watched);
        final input = StreamController<Object?>();
        final opened = Completer<String>();
        final firstPass = Completer<void>();
        final reads = _ForegroundFixture(cloud);
        final loop = WorkerLoop(
          engine,
          (event) {
            final value = event as Map;
            if (value['event'] == 'open') {
              opened.complete(File(value['path'] as String).readAsStringSync());
            }
            if (value['event'] == 'state' &&
                value['status'] == SyncStatus.upToDate.name &&
                !firstPass.isCompleted) {
              firstPass.complete();
            }
          },
          interval: const Duration(milliseconds: 100),
          foregroundReads: () => reads,
        );
        final done = loop.run(input.stream);
        try {
          await phoneFs.enumerating.future.timeout(wait);
          input.add({
            'action': 'open',
            'path': selected,
            'providerTracked': true,
          });
          expect(await opened.future.timeout(wait), 'selected file');
          expect(engine.lastPass, isNull);
          expect(remote('Videos/a.txt'), isNull);
          expect(phoneFs.meter.filesBy['scan'], isNull);
          if (w != null) {
            // This event comes from a watch attached by the private traversal
            // whose descriptor has yet to be registered with the worker.
            expect(w.watching('Unrelated'), isFalse);
            final delivered = Completer<void>();
            final onChange = w.onChange;
            w.onChange = () {
              onChange?.call();
              if (!delivered.isCompleted) delivered.complete();
            };
            local('Unrelated/arrived.txt')
                .writeAsStringSync('arrived mid-audit');
            await delivered.future.timeout(wait);
          }
          phoneFs.resume.complete();
          await firstPass.future.timeout(wait);
          expect(remote('Videos/a.txt'), 'in Movies');
          if (w != null) {
            expect(w.watching('Unrelated'), isTrue);
            final deadline = Stopwatch()..start();
            while (remote('Unrelated/arrived.txt') == null) {
              if (deadline.elapsed > wait) fail('mid-audit event was lost');
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(remote('Unrelated/arrived.txt'), 'arrived mid-audit');
            expect(engine.fullVerifications, 1);
          }
        } finally {
          if (!phoneFs.resume.isCompleted) phoneFs.resume.complete();
          input.add({'action': 'stop'});
          await done;
          await input.close();
        }
      },
    );
  }

  for (final interrupt in ['network', 'pause', 'certificate renewal']) {
    test(
      'a selected response cannot publish Connected after $interrupt',
      () async {
        const selected = 'read-first.txt';
        addCloudOnly(selected);
        final root = Completer<void>();
        final rootStarted = Completer<void>();
        final file = Completer<void>();
        final fileStarted = Completer<void>();
        final input = StreamController<Object?>();
        final observed = <String>[];
        final openingDone = Completer<void>();
        final settled = Completer<void>();
        var reads = _ForegroundFixture(
          cloud,
          beforeRoot: () {
            if (!rootStarted.isCompleted) rootStarted.complete();
            return root.future;
          },
          beforeFile: () {
            fileStarted.complete();
            return file.future;
          },
        );
        final loop = WorkerLoop(engine, (event) {
          final value = event as Map;
          if (value['status'] case final String status) {
            observed.add(status);
            if (status == SyncStatus.upToDate.name && !settled.isCompleted) {
              settled.complete();
            }
          }
          if (value['event'] == 'openNotice' &&
              (value['message'] as String?)?.startsWith('Opening') != true) {
            if (!openingDone.isCompleted) openingDone.complete();
          }
        }, foregroundReads: () => reads);
        input.add({'action': 'network', 'online': true, 'wifi': true});
        final done = loop.run(input.stream);
        try {
          await rootStarted.future.timeout(wait);
          input.add({'action': 'open', 'path': selected});
          await fileStarted.future.timeout(wait);
          switch (interrupt) {
            case 'network':
              input.add({'action': 'network', 'online': false, 'wifi': false});
            case 'pause':
              input.add({'action': 'pause'});
            case 'certificate renewal':
              reads = _ForegroundFixture(cloud);
          }
          await Future<void>.delayed(Duration.zero);
          file.complete();
          await openingDone.future.timeout(wait);
          expect(observed, isNot(contains(SyncStatus.checkingChanges.name)));
          if (interrupt == 'certificate renewal') {
            root.complete();
            await settled.future.timeout(wait);
            expect(observed, contains(SyncStatus.checkingChanges.name));
          }
        } finally {
          if (!file.isCompleted) file.complete();
          if (!root.isCompleted) root.complete();
          input.add({'action': 'stop'});
          await done;
          await input.close();
          closed = true;
        }
      },
    );
  }

  test('the watch limit fallback verifies once, then audits by stat', () async {
    await engine.tick();
    await quiesce();
    watcher().native.watchDebugFailAdds(watcher().handle, 'Documents/Full');
    Directory('${tree.root.path}/Documents/Full/a').createSync(recursive: true);
    local('Documents/Full/a/x.txt').writeAsStringSync('x');
    await pump(() => remote('Documents/Full/a/x.txt') == 'x');
    expect(watcher().exhausted, greaterThan(0));
    await engine.tick();
    expect(engine.fullVerifications, 2);
    final after = engine.fullVerifications;
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
    expect(engine.fullVerifications, after, reason: 'not repeated per pass');
  });

  test('foreground entry verifies and Downloader refresh only lists', () async {
    engine.close();
    closed = true;
    Future<int> verificationsAfter(Map<String, Object> shown) async {
      final value = await open(
        () => SyncEngine(
          Manifest(Directory('${fixture.path}/profile')),
          RootTree(tree.root, tree.staging, fs),
          cloud,
          watchers: const AndroidChangeWatchers(),
        ),
      );
      final input = StreamController<Object?>();
      final reads = _ForegroundFixture(cloud);
      final loop = WorkerLoop(
        value,
        (_) {},
        interval: const Duration(milliseconds: 100),
        schedule: RemoteSchedule(idle: const Duration(seconds: 30)),
        foregroundReads: () => reads,
      );
      final done = loop.run(input.stream);
      try {
        final end = Stopwatch()..start();
        while (value.lastPass == null || value.lastPass!.filesHashed != 0) {
          if (end.elapsed > wait) fail('did not settle');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final before = value.fullVerifications;
        final listedBefore = cloud.listings;
        final hashedBefore = fs.meter.filesBy['scan'];
        input.add(shown);
        while (cloud.listings == listedBefore) {
          if (end.elapsed > wait) fail('refresh did not list');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (shown['verify'] != true) {
          expect(fs.meter.filesBy['scan'], hashedBefore);
        }
        return value.fullVerifications - before;
      } finally {
        input.add({'action': 'stop'});
        await done;
        await input.close();
      }
    }

    expect(
      await verificationsAfter({'action': 'visible', 'verify': true}),
      1,
      reason: 'Android entry: the app opened',
    );
    expect(
      await verificationsAfter({'action': 'visible'}),
      0,
      reason: 'Downloader sends visible without verify',
    );
  });

  test('no back-to-back timer passes while nothing changed', () async {
    engine.close();
    closed = true;
    Future<int> passesIn(SyncEngine value, Duration span) async {
      final input = StreamController<Object?>();
      final loop = WorkerLoop(
        value,
        (_) {},
        interval: const Duration(milliseconds: 100),
        schedule: RemoteSchedule(idle: const Duration(seconds: 30)),
      );
      final done = loop.run(input.stream);
      await Future<void>.delayed(const Duration(seconds: 1));
      // Each pass replaces lastPass; sample often enough to see every one.
      var count = 0;
      var last = value.lastPass;
      final end = DateTime.now().add(span);
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (!identical(value.lastPass, last)) {
          count++;
          last = value.lastPass;
        }
      }
      input.add({'action': 'stop'});
      await done;
      await input.close();
      return count;
    }

    final android = await open(
      () => SyncEngine(
        Manifest(Directory('${fixture.path}/profile')),
        RootTree(tree.root, tree.staging, fs),
        cloud,
        watchers: const AndroidChangeWatchers(),
      ),
    );
    final idle = await passesIn(android, const Duration(seconds: 2));
    expect(idle, lessThanOrEqualTo(1), reason: 'quiet: wait for the listing');

    final linuxTree = RootTree(
      tree.root,
      tree.staging,
      NativeRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']),
    )..vmDirectory = '${fixture.path}/no-vm';
    final linux = await open(
      () => SyncEngine(
        Manifest(Directory('${fixture.path}/profile')),
        linuxTree,
        cloud,
        watchers: const LinuxChangeWatchers(),
      ),
    );
    final linuxPasses = await passesIn(linux, const Duration(seconds: 2));
    expect(linuxPasses, greaterThanOrEqualTo(5), reason: 'Linux unchanged');
  });

  group('interrupted install (decision #130 (4))', () {
    test('a leftover copy is removed at start; a recorded name is kept', () {
      engine.close();
      closed = true;
      final stage = tree.staging.path;
      final leftover = '${Artifacts.installTempPrefix}4242-0';
      final recorded = '${Artifacts.installTempPrefix}4242-1';
      File('$stage/$leftover').writeAsStringSync('half a copy');
      File('$stage/$recorded').writeAsStringSync('named by a record');
      File('$stage/download-x').writeAsStringSync('not an install copy');
      final again = Manifest(Directory('${fixture.path}/profile'));
      final op = Operation(
        uniqueId(),
        'artifact',
        'Documents/r.txt',
        staged: '$stage/$recorded',
        phase: 'reserved',
      )..data = {'role': 'download', 'name': recorded};
      again.operations[op.id] = op;
      again.save();
      final reopened = RootTree(tree.root, tree.staging, fs);
      // Before the cleanup the leftover makes staging uncertain, which
      // holds back Cloud release.
      expect(Artifacts(again, reopened).hasLegacyOrUncertain, isTrue);
      final probe = SyncEngine(again, reopened, cloud);
      expect(probe.interruptedInstalls, [leftover]);
      expect(File('$stage/$leftover').existsSync(), isFalse);
      expect(File('$stage/$recorded').existsSync(), isTrue);
      expect(File('$stage/download-x').existsSync(), isTrue);
      probe.close();
    });

    test('with only a leftover, staging is certain again after start', () {
      engine.close();
      closed = true;
      File('${tree.staging.path}/${Artifacts.installTempPrefix}1-0')
          .writeAsStringSync('x');
      final again = Manifest(Directory('${fixture.path}/profile'));
      final reopened = RootTree(tree.root, tree.staging, fs);
      expect(Artifacts(again, reopened).hasLegacyOrUncertain, isTrue);
      final probe = SyncEngine(again, reopened, cloud);
      expect(probe.interruptedInstalls, hasLength(1));
      expect(probe.artifacts.hasLegacyOrUncertain, isFalse);
      probe.close();
    });
  });
}
