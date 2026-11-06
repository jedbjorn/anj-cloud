@TestOn('windows')
library;

import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// Decision #137 (3) on W10C-Testing (PR #84 review, finding 1): between
/// full verifications the 5-minute stat audit reads only files whose stat
/// stamp changed. Over NTFS and the ReadDirectoryChangesW watcher, two audits
/// of an unchanged root read nothing, and neither does a hint naming a
/// folder. The stamps a scan reports before and after one content read are
/// printed ("WW stamp"): a read moves LastAccess, never the stamp.
void main() {
  late Directory temp;
  late NativeRootFs fs;
  late RootTree tree;
  late SyncEngine engine;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anj-ww-audit-');
    fs = platformAdapters().rootFilesystem() as NativeRootFs;
    tree = RootTree.setup(temp.path, 'audit', fs);
    for (var i = 0; i < 20; i++) {
      File(p.join(tree.root.path, 'Documents', 'f$i.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('file $i');
    }
  });
  tearDown(() {
    engine.close();
    temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> stat(String path) =>
      fs.watchScan(null, tree.fd, path, false).items.single;

  test('two stat audits of an unchanged root read no file', () async {
    const path = 'Documents/f0.txt';
    final file = File(p.join(tree.root.path, path));
    final before = stat(path), accessedBefore = file.statSync().accessed;
    fs.copyAndHashStamped(tree.fd, path, null, purpose: 'scan');
    final after = stat(path), accessedAfter = file.statSync().accessed;
    // ignore: avoid_print
    print(
      'WW stamp before read: mtime ${before['mtime']} ctime ${before['ctime']} '
      'inode ${before['inode']} size ${before['size']} '
      'lastAccess ${accessedBefore.toUtc().toIso8601String()}',
    );
    // ignore: avoid_print
    print(
      'WW stamp after read:  mtime ${after['mtime']} ctime ${after['ctime']} '
      'inode ${after['inode']} size ${after['size']} '
      'lastAccess ${accessedAfter.toUtc().toIso8601String()}',
    );

    final store = Manifest(Directory(p.join(temp.path, 'profile')))
      ..setSetting('retention', 'local');
    final cloud = FakeCloud();
    engine = SyncEngine(
      store,
      tree,
      cloud,
      watchers: const WindowsChangeWatchers(),
    );
    await engine.startWatching();
    final watcher = engine.watcher! as LocalWatcher
      ..quiet = const Duration(milliseconds: 150)
      ..maxDelay = const Duration(seconds: 2);
    expect(engine.eventDriven, isTrue);
    // The first pass verifies; then calm (nothing queued, nothing read).
    var calm = 0;
    for (var i = 0; i < 200 && calm < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      calm = watcher.queued == 0 && engine.lastPass!.filesHashed == 0
          ? calm + 1
          : 0;
    }
    expect(calm, 4, reason: 'quiesced');
    expect(cloud.files.length, 20);
    final verifications = engine.fullVerifications;
    final hashed = <int>[];
    for (var audit = 0; audit < 2; audit++) {
      final scans = engine.fullScans;
      engine.statAuditInterval = Duration.zero;
      await engine.tick();
      engine.statAuditInterval = const Duration(minutes: 5);
      expect(engine.fullScans, scans + 1, reason: 'a stat audit ran');
      hashed.add(engine.lastPass!.filesHashedBy['scan'] ?? 0);
    }
    // ignore: avoid_print
    print(
      'WW audit: scan reads $hashed, fullVerifications '
      '$verifications -> ${engine.fullVerifications}',
    );
    expect(
      engine.fullVerifications,
      verifications,
      reason: 'not verifications',
    );
    expect(hashed, [0, 0], reason: 'an unchanged root is not read');

    // A hint naming a folder (only the root is watched on Windows) re-stats
    // beneath it and reads no unchanged file: what read all 1,000 files of
    // the idle root twice in run 9.
    final scans = engine.fullScans;
    watcher.enqueue('Documents');
    var read = 0;
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      read += engine.lastPass!.filesHashedBy['scan'] ?? 0;
    }
    // ignore: avoid_print
    print(
      'WW folder hint: scan reads $read, watched ${watcher.watching('Documents')}',
    );
    expect(watcher.queued, 0, reason: 'the hint was taken');
    expect(read, 0, reason: 'no unchanged file beneath the folder is read');
    expect(engine.fullScans, scans);
    expect(engine.fullVerifications, verifications);
  });
}
