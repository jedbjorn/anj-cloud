import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/cloud_names.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Per-device local names at the sync boundary (spec #49 R3, Sync Boundary;
/// decision #199): a Windows or macOS device holds every cloud item under a
/// local name it can store, silently, and every request leaves under the
/// cloud name. Runs anywhere through the [SyncEngine.nameOs] seam: this
/// Linux volume stores the Windows names as they are.
void main() {
  // The deletions under Documents here are not about their settle time;
  // top_folders_test.dart covers it.
  setUpAll(() => SyncEngine.debugTopDeleteSettleAll = Duration.zero);
  tearDownAll(() => SyncEngine.debugTopDeleteSettleAll = null);
  late Directory fixture;
  late Manifest store;
  late _CountingCloud cloud;
  late CloudNames names;
  late SyncEngine engine;

  /// One device on [os]; [profile] names a fresh manifest, so a second call
  /// with another one models unpair and re-pair on the existing root.
  void device(NameOs os, {String profile = 'profile-a'}) {
    final parent = Directory('${fixture.path}/a')..createSync(recursive: true);
    final tree = RootTree.setup(parent.path, profile, NativeRootFs());
    store = Manifest(Directory('${fixture.path}/$profile'));
    store.setSetting('retention', 'local');
    names = CloudNames();
    engine = SyncEngine(store, tree, NamedCloud(cloud, names), names: names)
      ..nameOs = os;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-names-test-');
    cloud = _CountingCloud();
    device(NameOs.windows);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${engine.tree.root.path}/$path');
  bool onDisk(String path) =>
      FileSystemEntity.typeSync('${engine.tree.root.path}/$path') !=
      FileSystemEntityType.notFound;
  String status(String path) => store.entries[path]!.status;
  List<String> onDiskIn(String folder) =>
      Directory('${engine.tree.root.path}/$folder')
          .listSync()
          .map((item) => item.path.split('/').last)
          .toList()
        ..sort();
  String? identity(String path) =>
      engine.tree.scanItems(includeExcluded: true)[path]?.identity;

  /// AC3's cloud items, the clash pair in fileid order.
  void ac3Items() {
    cloud.put('Documents/a:b?.txt', 'colon');
    cloud.put('Documents/CON.txt', 'device');
    cloud.put('Documents/x.', 'dot');
    cloud.put('Documents/Report.pdf', 'older');
    cloud.put('Documents/report.pdf', 'newer');
  }

  const windowsNames = [
    'CON_.txt',
    'Report.pdf',
    'a：b？.txt',
    'report (2).pdf',
    'x',
  ];

  test('Windows holds every AC3 item under its local name, silently '
      '(spec #49 AC4)', () async {
    ac3Items();
    await engine.tick();
    await engine.tick();
    expect(onDiskIn('Documents'), windowsNames);
    expect(local('Documents/a：b？.txt').readAsStringSync(), 'colon');
    expect(local('Documents/report (2).pdf').readAsStringSync(), 'newer');
    expect(local('Documents/Report.pdf').readAsStringSync(), 'older');
    for (final name in windowsNames) {
      final entry = store.entries['Documents/$name']!;
      expect(entry.status, 'current local', reason: name);
      final row = await projectEntry(engine, entry);
      expect(row['presentationErrors'], isEmpty, reason: name);
      expect(row['cantSyncName'], isFalse);
    }
    // No surface shows a local name: rows carry the cloud path.
    final row = await projectEntry(
      engine,
      store.entries['Documents/report (2).pdf']!,
    );
    expect(row['cloudPath'], 'Documents/report.pdf');
    expect(
      (await projectEntry(engine, store.entries['Documents/x']!))['cloudPath'],
      'Documents/x.',
    );
    expect(store.entries['Documents/x']!.cloudName, 'x.');
    expect(store.entries['Documents/Report.pdf']!.cloudName, isNull);
    // Nothing was uploaded, renamed or deleted in the cloud.
    expect(cloud.uploads, 0);
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
  });

  test('an edit uploads under the cloud name; a local rename renames the '
      'cloud item to the new name, literally (AC4)', () async {
    ac3Items();
    await engine.tick();
    local('Documents/a：b？.txt').writeAsStringSync('edited', flush: true);
    local('Documents/report (2).pdf').writeAsStringSync('newer 2', flush: true);
    await engine.tick();
    expect(cloud.files['Documents/a:b?.txt'], 'edited'.codeUnits);
    expect(cloud.files['Documents/report.pdf'], 'newer 2'.codeUnits);
    expect(cloud.files['Documents/Report.pdf'], 'older'.codeUnits);
    expect(cloud.files.keys.where((k) => k.contains('：')), isEmpty);
    expect(cloud.files.keys.where((k) => k.contains('(2)')), isEmpty);
    local('Documents/a：b？.txt')
        .renameSync('${engine.tree.root.path}/Documents/c.txt');
    await engine.tick();
    await engine.tick();
    expect(cloud.moves, ['Documents/a:b?.txt -> Documents/c.txt']);
    expect(cloud.files['Documents/c.txt'], 'edited'.codeUnits);
    expect(status('Documents/c.txt'), 'current local');
  });

  test('a file moved under its local name keeps its cloud name, into and '
      'out of a translated folder; a new local name is literal (Reverse '
      'direction)', () async {
    await cloud.mkdir('Documents/Trip?');
    cloud.put('Documents/Trip?/x.', 'x');
    cloud.put('Documents/a.txt', 'a');
    await cloud.mkdir('Documents/Archive');
    await engine.tick();
    await engine.tick();
    expect(onDisk('Documents/Trip？/x'), isTrue);
    expect(
      (await projectEntry(
        engine,
        store.entries['Documents/Trip？/x']!,
      ))['cloudPath'],
      'Documents/Trip?/x.',
    );
    local('Documents/Trip？/x')
        .renameSync('${engine.tree.root.path}/Documents/Archive/x');
    local('Documents/a.txt')
        .renameSync('${engine.tree.root.path}/Documents/Trip？/a.txt');
    await engine.tick();
    await engine.tick();
    expect(cloud.moves..sort(), [
      'Documents/Trip?/x. -> Documents/Archive/x.',
      'Documents/a.txt -> Documents/Trip?/a.txt',
    ]);
    expect(cloud.files['Documents/Archive/x.'], 'x'.codeUnits);
    expect(cloud.files['Documents/Trip?/a.txt'], 'a'.codeUnits);
    expect(store.entries['Documents/Archive/x']!.cloudName, 'x.');
    // A local name no listed item has is taken literally.
    local('Documents/new：name.txt').writeAsStringSync('new', flush: true);
    await engine.tick();
    expect(cloud.files['Documents/new：name.txt'], 'new'.codeUnits);
    expect(cloud.files.containsKey('Documents/new:name.txt'), isFalse);
  });

  test('the boundary maps per segment, both ways; an unknown local name '
      'is literal', () {
    final names = CloudNames()
      ..listed(
        {'Docs/Trip？': 'Trip?', 'Docs/Trip？/x': 'x.'},
        {'Docs/Trip?': 'Docs/Trip？', 'Docs/Trip?/x.': 'Docs/Trip？/x'},
      );
    expect(names.cloudPath('Docs/Trip？/x'), 'Docs/Trip?/x.');
    expect(names.cloudPath('Docs/Trip？/new：y'), 'Docs/Trip?/new：y');
    expect(names.cloudPath('Docs/other'), 'Docs/other');
    expect(names.localPath('Docs/Trip?/x.'), 'Docs/Trip？/x');
    expect(names.localPath('Docs/Trip?/deeper/z'), 'Docs/Trip？/deeper/z');
    expect(names.localPath('Docs/other'), 'Docs/other');
    // A move keeps the cloud name only when it keeps the local name.
    expect(names.movedCloudPath('Docs/Trip？/x', 'Docs/x'), 'Docs/x.');
    expect(names.movedCloudPath('Docs/Trip？/x', 'Docs/y'), 'Docs/y');
    expect(names.movedCloudPath('Docs/a', 'Docs/Trip？/a'), 'Docs/Trip?/a');
  });

  test('AC6: a fresh profile on the existing root rebuilds every local name '
      'from the listing: no upload, no conflict copy', () async {
    ac3Items();
    await cloud.mkdir('Documents/Trip?');
    cloud.put('Documents/Trip?/day.txt', 'day');
    await engine.tick();
    await engine.tick();
    final before = onDiskIn('Documents');
    final uploads = cloud.uploads, downloads = cloud.completedDownloads;
    engine.close();
    device(NameOs.windows, profile: 'profile-b');
    expect(store.entries, isEmpty);
    await engine.tick();
    await engine.tick();
    expect(onDiskIn('Documents'), before);
    expect(onDiskIn('Documents/Trip？'), ['day.txt']);
    expect(cloud.uploads, uploads, reason: 'no duplicate upload');
    expect(cloud.moves, isEmpty);
    expect(cloud.deletes, 0);
    // A fresh profile compares each existing file with one download, as it
    // does with no local names at all; nothing beyond that.
    expect(cloud.completedDownloads - downloads, 6);
    expect(cloud.files.keys.toSet(), {
      'Documents/a:b?.txt',
      'Documents/CON.txt',
      'Documents/x.',
      'Documents/Report.pdf',
      'Documents/report.pdf',
      'Documents/Trip?/day.txt',
    });
    expect(store.entries['Documents/x']!.cloudName, 'x.');
    expect(store.entries['Documents/report (2).pdf']!.cloudName, 'report.pdf');
    expect(store.entries['Documents/Trip？']!.cloudName, 'Trip?');
    for (final entry in store.entries.values) {
      expect(entry.conflict, isNull, reason: entry.path);
      expect(entry.path, isNot(contains('conflict')));
    }
  });

  test('cloud names survive a restart before the first listing', () async {
    ac3Items();
    await engine.tick();
    final reopened = {
      for (final entry in store.entries.values)
        entry.path: Entry.fromJson(entry.toJson()),
    };
    expect(reopened['Documents/x']!.cloudName, 'x.');
    final fresh = CloudNames()..recorded = (path) => reopened[path]?.cloudName;
    expect(fresh.cloudPath('Documents/x'), 'Documents/x.');
    expect(fresh.cloudPath('Documents/report (2).pdf'), 'Documents/report.pdf');
    expect(
      fresh.cloudPath('Documents/unknown (2).pdf'),
      'Documents/unknown (2).pdf',
    );
  });

  test('AC7: when the clash partner is deleted, `report (2).pdf` becomes '
      '`report.pdf` in place: same file, no transfer', () async {
    ac3Items();
    await engine.tick();
    await engine.tick();
    final kept = identity('Documents/report (2).pdf');
    expect(kept, isNotNull);
    final uploads = cloud.uploads, downloads = cloud.completedDownloads;
    // Deleted from another (Linux) device.
    cloud.remove('Documents/Report.pdf');
    for (var pass = 0; pass < 4; pass++) {
      await engine.tick();
    }
    expect(onDisk('Documents/report (2).pdf'), isFalse);
    expect(local('Documents/report.pdf').readAsStringSync(), 'newer');
    expect(identity('Documents/report.pdf'), kept, reason: 'renamed in place');
    expect(cloud.uploads, uploads);
    expect(cloud.completedDownloads, downloads);
    expect(cloud.moves, isEmpty, reason: 'a local rename only');
    expect(cloud.files.keys.where((k) => k.contains('report')), [
      'Documents/report.pdf',
    ]);
    expect(status('Documents/report.pdf'), 'current local');
    // The fileid-paired row moved to the new local name.
    expect(store.entries.containsKey('Documents/report (2).pdf'), isFalse);
    expect(store.entries['Documents/report.pdf']!.fileId, isNotNull);
    expect(onDisk('Documents/Report.pdf'), isFalse);
  });

  test('macOS resolves clashes only (AC5)', () async {
    engine.close();
    fixture.deleteSync(recursive: true);
    fixture = Directory.systemTemp.createTempSync('anj-names-test-');
    device(NameOs.macos);
    ac3Items();
    await engine.tick();
    expect(onDiskIn('Documents'), [
      'CON.txt',
      'Report.pdf',
      'a:b?.txt',
      'report (2).pdf',
      'x.',
    ]);
    expect(status('Documents/report (2).pdf'), 'current local');
  });

  test('Linux keeps every name verbatim (AC3)', () async {
    engine.nameOs = NameOs.linux;
    ac3Items();
    await engine.tick();
    expect(onDiskIn('Documents'), [
      'CON.txt',
      'Report.pdf',
      'a:b?.txt',
      'report.pdf',
      'x.',
    ]);
    expect(store.entries.values.where((e) => e.cloudName != null), isEmpty);
  });

  test('a cloud item no ` (n)` fits beside its extension is the one '
      'residual row, Cloud-only (decision #198)', () async {
    // 101 names one fold key apart: the 101st needs ` (101)`, and a
    // 248-character extension leaves no stem for it in 255 units.
    final extension = 'x' * 248;
    final variants = [
      'a.$extension',
      for (var i = 0; i < 100; i++)
        'a.${extension.substring(0, i)}X${extension.substring(i + 1)}',
    ];
    for (final name in variants) {
      cloud.put('Documents/$name', name.substring(0, 8));
    }
    await engine.tick();
    // ` (2)` to ` (99)` fit; ` (100)` leaves no stem, for the last two.
    for (final name in variants.skip(99)) {
      expect(status('Documents/$name'), unplaceableStatus);
      expect(onDisk('Documents/$name'), isFalse);
    }
    final last = 'Documents/${variants.last}';
    expect(onDiskIn('Documents'), hasLength(99));
    expect(cloud.files, hasLength(101), reason: 'nothing deleted');
    expect(cloud.uploads, 0);
    final row = await projectEntry(engine, store.entries[last]!);
    expect(row['presentationErrors'], [unplaceableStatus]);
    expect(row['cantSyncName'], isFalse, reason: 'nothing here to rename');
  });

  test('a long path syncs with the note', () async {
    final deep = [
      'Documents',
      for (var i = 0; i < 3; i++) 'segment-$i-${'d' * 80}',
      'deep.txt',
    ].join('/');
    cloud.put(deep, 'deep');
    engine.notesLongPaths = true;
    await engine.tick();
    expect(onDisk(deep), isTrue);
    final row = await projectEntry(engine, store.entries[deep]!);
    expect(row['presentationNotes'], [longPathNote]);
    expect(row['presentationErrors'], isEmpty);
    final short = await projectEntry(engine, store.entries['Documents']!);
    expect(short['presentationNotes'], isEmpty);
  });

  test('a held clash never needs attention', () async {
    SyncStatus overall() => deriveStatus(
      paused: false,
      offline: false,
      unpaired: false,
      message: engine.message,
      entries: store.entries.values,
      operations: store.operations.values,
    );
    ac3Items();
    await engine.tick();
    expect(overall(), isNot(SyncStatus.attention));
  });

  test('this Linux volume is case-sensitive', () {
    expect(engine.tree.native.caseInsensitive(engine.tree.root.path), isFalse);
  });

  test('10,000 siblings are named once per folder (time bound)', () {
    final entries = [
      for (var i = 0; i < 5000; i++) ...[
        NameEntry('file-$i.txt', fileId: 2 * i),
        NameEntry('FILE-$i.txt', fileId: 2 * i + 1),
      ],
    ];
    final watch = Stopwatch()..start();
    final local = NameRule.localNames(entries, NameOs.windows);
    watch.stop();
    expect(
      local.values.where((name) => name!.endsWith(' (2).txt')),
      hasLength(5000),
    );
    // Per-name sibling grouping is quadratic: seconds for 3,000 names.
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('the engine names a folder of 2,000 clash pairs in one pass, with no '
      'per-file listing', () async {
    const pairs = 1000;
    for (var i = 0; i < pairs; i++) {
      cloud.put('Big/file-$i.txt', '');
      cloud.put('Big/FILE-$i.txt', '');
    }
    store.setSetting('retention', 'cloud');
    final listings = cloud.listings;
    await engine.tick();
    expect(cloud.listings - listings, 1);
    expect(
      store.entries.keys.where((path) => path.endsWith(' (2).txt')),
      hasLength(pairs),
    );
    expect(
      store.entries.values.where((entry) => entry.cloudName != null),
      hasLength(pairs),
    );
  });
}

/// Counts listings, to prove names come from one listing per pass.
class _CountingCloud extends FakeCloud {
  int listings = 0;
  final uploaded = <String>[];
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    uploaded.add('$path@$etag');
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<List<RemoteItem>> snapshot() {
    listings++;
    return super.snapshot();
  }
}
