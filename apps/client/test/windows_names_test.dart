import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_holds.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Spec #32 W4, decision #120 Q2: on a device that cannot hold every name
/// the server can, a server item that cannot be created here stays
/// Cloud-only with its reason, and the kept clash sibling never flips. Two
/// gates: Win32 names (Windows) and a case-folding root volume (Windows,
/// default macOS). Runs anywhere through the test seams.
void main() {
  // The deletion under Documents here is not about the settle time of spec
  // #34 P7 (H1); top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;

  /// Windows: Win32 names and case folding. macOS: case folding only.
  void device({required bool windows, bool watch = false}) {
    final parent = Directory('${fixture.path}/a')..createSync();
    final tree = RootTree.setup(parent.path, 'a', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile-a'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine =
        SyncEngine(
            store,
            tree,
            cloud,
            watchers: watch ? const LinuxChangeWatchers() : null,
          )
          ..holdsAnyName = !windows
          ..foldsCase = true;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-names-test-');
    device(windows: true);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  bool onDisk(String path) =>
      FileSystemEntity.typeSync('${engine.tree.root.path}/$path') !=
      FileSystemEntityType.notFound;
  String status(String path) => store.entries[path]!.status;

  test('names Windows cannot hold stay Cloud-only with their reason', () async {
    for (final name in ['CON', 'nul.txt', 'x.', 'trailing ', 'ok.txt']) {
      cloud.put('Documents/names/$name', 'server $name');
    }
    await cloud.mkdir('Documents/bad.');
    cloud.put('Documents/bad./inside.txt', 'inside');
    await engine.tick();
    for (final name in ['CON', 'nul.txt', 'x.', 'trailing ']) {
      final path = 'Documents/names/$name';
      expect(onDisk(path), isFalse, reason: name);
      expect(status(path), serverNameNotAllowedStatus, reason: name);
    }
    expect(onDisk('Documents/names/ok.txt'), isTrue);
    expect(onDisk('Documents/bad.'), isFalse);
    expect(status('Documents/bad.'), serverNameNotAllowedStatus);
    expect(status('Documents/bad./inside.txt'), serverFolderNameStatus);
    // Amber with its reason, but no Rename: this device has no copy to
    // rename (Rename is for local names, decision #120).
    final row = await projectEntry(
      engine,
      store.entries['Documents/names/CON']!,
    );
    expect(row['nameRefused'], isFalse);
    expect(row['presentationErrors'], [serverNameNotAllowedStatus]);
    expect(cloud.files.containsKey('Documents/names/CON'), isTrue);
    expect(cloud.deletes, 0);
  });

  test('a name over 255 UTF-16 units stays Cloud-only on Windows; a long '
      'path syncs with the note', () async {
    final tooLong = '${'n' * 252}.txt';
    cloud.put('Documents/$tooLong', 'long name');
    final deep = [
      'Documents',
      for (var i = 0; i < 3; i++) 'segment-$i-${'d' * 80}',
      'deep.txt',
    ].join('/');
    cloud.put(deep, 'deep');
    engine.notesLongPaths = true;
    await engine.tick();
    expect(status('Documents/$tooLong'), serverNameNotAllowedStatus);
    expect(onDisk('Documents/$tooLong'), isFalse);
    expect(onDisk(deep), isTrue);
    final row = await projectEntry(engine, store.entries[deep]!);
    expect(row['presentationNotes'], [longPathNote]);
    expect(row['presentationErrors'], isEmpty);
    final short = await projectEntry(engine, store.entries['Documents']!);
    expect(short['presentationNotes'], isEmpty);
  });

  test(
    'a case clash keeps the byte-wise first name, stable over passes',
    () async {
      cloud.put('Documents/A.txt', 'upper');
      cloud.put('Documents/a.txt', 'lower');
      for (var pass = 0; pass < 3; pass++) {
        await engine.tick();
        expect(
          File('${engine.tree.root.path}/Documents/A.txt').readAsStringSync(),
          'upper',
        );
        expect(status('Documents/a.txt'), serverNameClashStatus);
        expect(status('Documents/A.txt'), 'current local');
      }
    },
  );

  test('a clash sibling already on this device is the one kept', () async {
    cloud.put('Documents/a.txt', 'lower first');
    await engine.tick();
    cloud.put('Documents/A.txt', 'upper later');
    await engine.tick();
    await engine.tick();
    expect(onDisk('Documents/a.txt'), isTrue);
    expect(status('Documents/A.txt'), serverNameClashStatus);
    expect(
      File('${engine.tree.root.path}/Documents/a.txt').readAsStringSync(),
      'lower first',
    );
  });

  test('the kept sibling survives a Cloud then Local cycle '
      '(the manifest, not the disk, records it)', () async {
    final a = File('${engine.tree.root.path}/Documents/a.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('local lower');
    await engine.tick();
    cloud.put('Documents/A.txt', 'server upper');
    await engine.tick();
    expect(status('Documents/A.txt'), serverNameClashStatus);
    engine.setRetention('Documents', Retention.cloud);
    await engine.tick();
    expect(a.existsSync(), isFalse, reason: 'released to the cloud');
    engine.setRetention('Documents', Retention.local);
    for (var pass = 0; pass < 3; pass++) {
      await engine.tick();
      expect(a.readAsStringSync(), 'local lower');
      expect(onDisk('Documents/A.txt'), isFalse);
      expect(status('Documents/A.txt'), serverNameClashStatus);
      expect(status('Documents/a.txt'), isNot(serverNameClashStatus));
    }
  });

  test('a clash loser comes down once its sibling is gone', () async {
    cloud.put('Documents/A.txt', 'upper');
    cloud.put('Documents/a.txt', 'lower');
    await engine.tick();
    expect(status('Documents/a.txt'), serverNameClashStatus);
    File('${engine.tree.root.path}/Documents/A.txt').deleteSync();
    await engine.tick();
    await engine.tick();
    expect(cloud.files.containsKey('Documents/A.txt'), isFalse);
    expect(
      File('${engine.tree.root.path}/Documents/a.txt').readAsStringSync(),
      'lower',
    );
  });

  test('watcher-driven passes: a held row is looked at again every pass, so '
      'the clash loser comes down once its sibling is gone', () async {
    // Passes that visit only changed paths: nothing changes at the held
    // row's own path, so only its unsettled state brings it back.
    engine.close();
    fixture.deleteSync(recursive: true);
    fixture = Directory.systemTemp.createTempSync('anj-names-test-');
    device(windows: true, watch: true);
    engine.watcherSettings = const WatcherSettings(
      quiet: Duration(milliseconds: 150),
      maxDelay: Duration(seconds: 2),
    );
    await engine.startWatching();
    Future<void> passesUntil(bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
      }
    }

    cloud.put('Documents/A.txt', 'upper');
    cloud.put('Documents/a.txt', 'lower');
    await passesUntil(() => onDisk('Documents/A.txt'));
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
    }
    expect(status('Documents/a.txt'), serverNameClashStatus);
    expect(engine.lastPass!.full, isFalse, reason: 'ordinary passes now');
    final fullScans = engine.fullScans;
    File('${engine.tree.root.path}/Documents/A.txt').deleteSync();
    await passesUntil(() => onDisk('Documents/a.txt'));
    expect(cloud.files.containsKey('Documents/A.txt'), isFalse);
    expect(
      File('${engine.tree.root.path}/Documents/a.txt').readAsStringSync(),
      'lower',
    );
    expect(engine.fullScans, fullScans, reason: 'no full scan did it');
  });

  test('a held server name needs attention app-wide and is amber on its row; '
      'removing the hold clears both', () async {
    SyncStatus overall() => deriveStatus(
      paused: false,
      offline: false,
      unpaired: false,
      message: engine.message,
      entries: store.entries.values,
      operations: store.operations.values,
    );
    cloud.put('Documents/ok.txt', 'fine');
    await engine.tick();
    expect(overall(), isNot(SyncStatus.attention));
    cloud.put('Documents/CON', 'held');
    await engine.tick();
    expect(status('Documents/CON'), serverNameNotAllowedStatus);
    expect(overall(), SyncStatus.attention);
    final row = await projectEntry(engine, store.entries['Documents/CON']!);
    expect(row['presentationErrors'], [serverNameNotAllowedStatus]);
    expect(row['nameRefused'], isFalse, reason: 'no Rename is offered');
    cloud.files.remove('Documents/CON');
    await engine.tick();
    await engine.tick();
    expect(overall(), isNot(SyncStatus.attention));
  });

  test('files under the losing folder of a clash stay Cloud-only', () async {
    // Real listings name the folders too.
    await cloud.mkdir('Documents/Docs');
    await cloud.mkdir('Documents/docs');
    cloud.put('Documents/Docs/x.txt', 'kept folder');
    cloud.put('Documents/docs/y.txt', 'losing folder');
    for (var pass = 0; pass < 3; pass++) {
      await engine.tick();
      expect(onDisk('Documents/Docs/x.txt'), isTrue);
      // Never created inside the kept folder by a case-blind filesystem.
      expect(onDisk('Documents/Docs/y.txt'), isFalse);
      expect(onDisk('Documents/docs'), isFalse);
      expect(status('Documents/docs'), serverNameClashStatus);
      expect(status('Documents/docs/y.txt'), serverFolderNameStatus);
    }
    expect(cloud.files.keys, isNot(contains('Documents/Docs/y.txt')));
    expect(cloud.files.containsKey('Documents/docs/y.txt'), isTrue);
    expect(cloud.deletes, 0);
  });

  test('a local-only folder clashes with a server folder too', () async {
    await engine.tick();
    // Created on this device, not (yet) on the server.
    Directory('${engine.tree.root.path}/Documents/Docs')
        .createSync(recursive: true);
    await cloud.mkdir('Documents/docs');
    cloud.put('Documents/docs/y.txt', 'server');
    await engine.tick();
    await engine.tick();
    expect(onDisk('Documents/Docs/y.txt'), isFalse);
    expect(status('Documents/docs/y.txt'), serverFolderNameStatus);
    expect(cloud.files.containsKey('Documents/docs/y.txt'), isTrue);
  });

  test('macOS: a case-folding volume holds clashes back, but not Win32 '
      'names', () async {
    engine.close();
    fixture.deleteSync(recursive: true);
    fixture = Directory.systemTemp.createTempSync('anj-names-test-');
    device(windows: false);
    cloud.put('Documents/CON', 'reserved on Windows only');
    cloud.put('Documents/A.txt', 'upper');
    cloud.put('Documents/a.txt', 'lower');
    await engine.tick();
    expect(onDisk('Documents/CON'), isTrue);
    expect(onDisk('Documents/A.txt'), isTrue);
    expect(status('Documents/a.txt'), serverNameClashStatus);
  });

  test('a device that holds every name (Linux) is unchanged', () async {
    engine
      ..holdsAnyName = true
      ..foldsCase = false;
    cloud.put('Documents/x.', 'dot');
    cloud.put('Documents/A.txt', 'upper');
    cloud.put('Documents/a.txt', 'lower');
    await engine.tick();
    expect(onDisk('Documents/x.'), isTrue);
    expect(onDisk('Documents/A.txt'), isTrue);
    expect(onDisk('Documents/a.txt'), isTrue);
  });

  test('this Linux volume is case-sensitive', () {
    expect(engine.tree.native.caseInsensitive(engine.tree.root.path), isFalse);
  });

  test('10,000 siblings are grouped once per folder (time bound)', () {
    final remote = <String>[
      for (var i = 0; i < 5000; i++) ...['Big/file-$i.txt', 'Big/FILE-$i.txt'],
    ];
    final watch = Stopwatch()..start();
    final holds = NameHolds(
      win32Names: true,
      foldsCase: true,
      remote: remote,
      local: const {},
      entries: const {},
    );
    var held = 0;
    for (final path in remote) {
      if (holds.status(path) != null) held++;
    }
    watch.stop();
    expect(held, 5000);
    // Quadratic grouping took seconds for 3,000 names (#73 review).
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test(
    'the engine groups a folder once per pass (linear in its size)',
    () async {
      // Every name in a clash pair, all new and Cloud-only. A first pass over
      // thousands of new Cloud-only items is slow in itself (entry creation),
      // so this counts the rule's work instead of timing the pass.
      const pairs = 1000;
      for (var i = 0; i < pairs; i++) {
        cloud.put('Big/file-$i.txt', '');
        cloud.put('Big/FILE-$i.txt', '');
      }
      store.setSetting('retention', 'cloud');
      NameHolds.debugFoldKeys = 0;
      await engine.tick();
      expect(
        store.entries.values.where((e) => e.status == serverNameClashStatus),
        hasLength(pairs),
      );
      // Each name is folded once to group it and once to look it up, with its
      // folder ('Big') looked up as an ancestor: about 4 per item, where
      // grouping per call would need pairs * 2 squared.
      expect(NameHolds.debugFoldKeys, lessThan(5 * 2 * pairs));
    },
  );
}
