// Decision #137 (2) on the VM host: on a case- or normalization-insensitive volume
// (APFS), a stat of a path finds an entry stored under another spelling, so
// a case-only rename must be resolved by the stored name, never by stat of
// the old one. The VM host's filesystems are byte-exact, so a fake binding answers
// lookups as APFS does: a path resolves case-insensitively and the stored
// spelling comes back ("stored", from ATTR_CMN_NAME in the Darwin build).
// The real APFS rename runs on mac-test.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The Linux binding, answering single-path lookups case-insensitively.
class _CaseInsensitiveFs extends NativeRootFs {
  _CaseInsensitiveFs()
    : super(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
        'Linux errno',
        const Duration(minutes: 60),
      );
  late String rootPath;
  int storedAnswers = 0;

  /// Hard links: a path whose stored name APFS reports as another link's
  /// name (ATTR_CMN_NAME may return any of them; PR #68 review).
  final Map<String, String> linkNames = {};

  /// [path] resolved component by component as a case-insensitive volume
  /// would: an exact name first, else the first case-insensitive match.
  String? _resolve(String path) {
    var at = '';
    for (final part in path.split('/')) {
      final dir = Directory(at.isEmpty ? rootPath : '$rootPath/$at');
      if (!dir.existsSync()) return null;
      final names = [
        for (final e in dir.listSync(followLinks: false))
          e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
      final hit = names.contains(part)
          ? part
          : names
                .where((n) => n.toLowerCase() == part.toLowerCase())
                .firstOrNull;
      if (hit == null) return null;
      at = at.isEmpty ? hit : '$at/$hit';
    }
    return at;
  }

  @override
  ({List<Map<String, dynamic>> items, List<Map<String, dynamic>> watches})
  watchScan(Pointer<Void>? handle, int root, String path, bool recursive) {
    final link = linkNames[path];
    if (link != null) {
      final found = super.watchScan(handle, root, path, recursive);
      return (
        items: [
          for (final (i, item) in found.items.indexed)
            i == 0 ? {...item, 'stored': link} : item,
        ],
        watches: found.watches,
      );
    }
    if (path.isNotEmpty) {
      final stored = _resolve(path);
      if (stored != null && stored != path) {
        storedAnswers++;
        final found = super.watchScan(null, root, stored, false);
        return (
          items: [
            for (final item in found.items.take(1))
              {...item, 'path': path, 'stored': stored},
          ],
          watches: const [],
        );
      }
    }
    return super.watchScan(handle, root, path, recursive);
  }
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late FakeCloud cloud;
  late SyncEngine engine;
  late _CaseInsensitiveFs fs;

  String? remote(String path) {
    final bytes = cloud.files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  Future<void> pump(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) {
        fail(
          'condition not reached: ${cloud.files.keys.toList()} '
          '${cloud.directories} ${engine.message} '
          '${engine.manifest.entries.keys.toList()}',
        );
      }
    }
  }

  setUp(() async {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-case-')
          .resolveSymbolicLinksSync(),
    );
    fs = _CaseInsensitiveFs();
    tree = RootTree.setup(fixture.path, 'root', fs)
      ..vmDirectory = '${fixture.path}/no-vm';
    fs.rootPath = tree.root.path;
    final store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    // Folder moves need qualified folders, as in case_only_move_test.dart.
    cloud = FakeCloud()..foldersQualified = true;
    engine = SyncEngine(
      store,
      tree,
      cloud,
      watchers: const LinuxChangeWatchers(),
    );
    await engine.startWatching();
    (engine.watcher! as LocalWatcher)
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  test('a case-only rename is resolved by the stored name, not a stat of '
      'the old one', () async {
    Directory('${tree.root.path}/Docs').createSync();
    File('${tree.root.path}/Docs/Report.txt').writeAsStringSync('report');
    await pump(() => remote('Docs/Report.txt') == 'report');
    expect(engine.eventDriven, isTrue);
    final verifications = engine.fullVerifications;
    File('${tree.root.path}/Docs/Report.txt')
        .renameSync('${tree.root.path}/Docs/report.txt');
    await pump(
      () =>
          remote('Docs/report.txt') == 'report' &&
          remote('Docs/Report.txt') == null,
    );
    expect(fs.storedAnswers, greaterThan(0), reason: 'the old name resolved');
    expect(engine.fullVerifications, verifications, reason: 'by events alone');
  });

  // With #71 (decisions #120, #138) the cloud side follows as one MOVE. Not
  // a standard folder (Photos), which the engine keeps in place.
  test(
    'a case-only folder rename moves the folder and what is beneath it',
    () async {
      Directory('${tree.root.path}/Albums/2026').createSync(recursive: true);
      File('${tree.root.path}/Albums/2026/a.jpg').writeAsStringSync('a');
      // Synchronized folders carry their cloud versions (from a listing).
      await pump(
        () =>
            remote('Albums/2026/a.jpg') == 'a' &&
            engine.manifest.entries['Albums']?.etag != null &&
            engine.manifest.entries['Albums/2026']?.etag != null,
      );
      Directory('${tree.root.path}/Albums')
          .renameSync('${tree.root.path}/albums');
      await pump(
        () =>
            remote('albums/2026/a.jpg') == 'a' &&
            remote('Albums/2026/a.jpg') == null,
      );
      expect(fs.storedAnswers, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('a hard-linked file whose stored name is another link is still '
      'present: an edit uploads, nothing is deleted', () async {
    Directory('${tree.root.path}/Docs').createSync();
    File('${tree.root.path}/Docs/a.txt').writeAsStringSync('one');
    final link = await Process.run('ln', [
      '${tree.root.path}/Docs/a.txt',
      '${tree.root.path}/Docs/b.txt',
    ]);
    expect(link.exitCode, 0);
    await pump(
      () => remote('Docs/a.txt') == 'one' && remote('Docs/b.txt') == 'one',
    );
    fs.linkNames['Docs/b.txt'] = 'Docs/a.txt';
    final deletes = cloud.deletes;
    File('${tree.root.path}/Docs/b.txt').writeAsStringSync('two');
    await pump(
      () => remote('Docs/b.txt') == 'two' && remote('Docs/a.txt') == 'two',
    );
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
    }
    expect(cloud.deletes, deletes, reason: 'no removal inferred');
    expect(remote('Docs/b.txt'), 'two');
    expect(engine.manifest.entries['Docs/b.txt']!.expectedPresent, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the stored spelling is rescanned in the same pass: a case-only '
      'rename pairs without the watcher delivering the new name', () async {
    Directory('${tree.root.path}/Notes').createSync();
    File('${tree.root.path}/Notes/Plan.txt').writeAsStringSync('plan');
    await pump(
      () =>
          remote('Notes/Plan.txt') == 'plan' &&
          engine.manifest.entries['Notes']?.etag != null,
    );
    // The watcher's own events never mature (its clock stands still), so
    // only the old name reaches this pass, as a path the engine touched.
    final w = engine.watcher! as LocalWatcher;
    w.debugNow = () => 0;
    File('${tree.root.path}/Notes/Plan.txt')
        .renameSync('${tree.root.path}/Notes/plan.txt');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    engine.markDirty('Notes/Plan.txt');
    await engine.tick();
    expect(
      engine.manifest.entries['Notes/plan.txt'],
      isNotNull,
      reason: 'the stored spelling was rescanned in this pass',
    );
    await pump(
      () =>
          remote('Notes/plan.txt') == 'plan' &&
          remote('Notes/Plan.txt') == null,
    );
    expect(cloud.deletes, 0, reason: 'a move, not a delete');
  }, timeout: const Timeout(Duration(minutes: 1)));
}
