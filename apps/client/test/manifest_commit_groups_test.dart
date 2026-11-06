// Flag SC-051: grouped manifest commits. Where a platform gives a
// CommitDurability (macOS), every commit is followed by a barrier before
// save() returns, and a full flush ends each group: after 64 commits, a
// second after the group's first commit, at every pass end, on a settings
// write and on close. Linux has none, so its commits are unchanged. The
// macOS fcntls themselves run on mac-test (test_macos/).
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/commit_durability.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/durability.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fakes.dart';
import 'test_platform.dart';

class _Recorder implements CommitDurability {
  final List<String> calls = [];
  bool fail = false;
  @override
  void barrier(String path) {
    if (fail) throw FileSystemException('refused', path);
    calls.add('barrier');
  }

  @override
  void flush(String path) {
    if (fail) throw FileSystemException('refused', path);
    calls.add('flush');
  }
}

void main() {
  late Directory fixture;
  setUp(() {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-groups-')
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  Directory profile() => Directory('${fixture.path}/profile');
  int fullfsync(Manifest m) =>
      m.db.select('PRAGMA fullfsync').first.values.first as int;
  void change(Manifest m, int i) {
    m.entries['f$i.txt'] = Entry('f$i.txt', ItemKind.file);
    m.save();
  }

  test('Linux: no grouping, every commit as before', () {
    expect(platformCommitDurability(), isNull);
    final m = Manifest(profile());
    try {
      expect(m.groupsCommits, isFalse);
      expect(fullfsync(m), 1);
      for (var i = 0; i < 5; i++) {
        change(m, i);
      }
      expect(m.transactions, 5);
      expect(m.barriers + m.flushes, 0);
    } finally {
      m.close();
    }
  }, skip: linuxOnly('macOS groups commits; the tests below cover it'));

  test('each commit is ordered by a barrier; a commit point flushes once', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    try {
      expect(fullfsync(m), 0, reason: 'SQLite syncs with plain fsync');
      for (var i = 0; i < 10; i++) {
        change(m, i);
      }
      expect(sync.calls, List.filled(10, 'barrier'));
      expect(m.unflushedCommits, 10);
      m.commitPoint();
      m.commitPoint(); // Nothing pending: no second flush.
      expect(sync.calls.last, 'flush');
      expect(m.flushes, 1);
      expect(m.unflushedCommits, 0);
    } finally {
      m.close();
    }
  });

  test('a group ends after 64 commits', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    try {
      for (var i = 0; i < Manifest.groupCommits; i++) {
        change(m, i);
      }
      expect(m.barriers, Manifest.groupCommits - 1);
      expect(m.flushes, 1, reason: 'the 64th commit ends the group');
      expect(m.unflushedCommits, 0);
    } finally {
      m.close();
    }
  });

  test('settings writes and close are commit points', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    change(m, 1);
    m.setSetting('paused', '1');
    expect(sync.calls, ['barrier', 'flush']);
    m.deleteSetting('paused');
    expect(sync.calls.last, 'flush');
    change(m, 2);
    m.close();
    expect(sync.calls.last, 'flush');
    // Everything committed is there after reopening.
    final again = Manifest(profile());
    try {
      expect(again.entries.keys, containsAll(['f1.txt', 'f2.txt']));
    } finally {
      again.close();
    }
  });

  test('a refused barrier returns to durable commits; the pending ones are '
      'made durable at the next commit point', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    try {
      change(m, 1);
      sync.fail = true;
      change(m, 2); // Committed; its barrier is refused.
      expect(m.entries.containsKey('f2.txt'), isTrue);
      expect(m.groupingDisabled, isTrue);
      expect(m.groupsCommits, isFalse);
      expect(fullfsync(m), 1);
      expect(m.unflushedCommits, 2, reason: 'not yet durable');
      m.commitPoint(); // A full checkpoint instead of the refused flush.
      expect(m.unflushedCommits, 0);
      sync.fail = false;
      change(m, 3);
      expect(sync.calls, ['barrier'], reason: 'no grouping after the failure');
    } finally {
      m.close();
    }
  });

  test('a refused flush at a commit point falls back to a full checkpoint', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    try {
      change(m, 1);
      sync.fail = true;
      m.commitPoint();
      expect(m.groupingDisabled, isTrue);
      expect(m.unflushedCommits, 0);
    } finally {
      m.close();
    }
  });

  test('a busy fallback checkpoint keeps the commits pending and fails the '
      'commit point (PR #68 review)', () {
    final sync = _Recorder();
    final m = Manifest(profile(), durability: sync);
    final reader = sqlite3.open('${profile().path}/manifest.sqlite');
    try {
      change(m, 1);
      // A reader on an older snapshot keeps a FULL checkpoint from finishing.
      reader.execute('BEGIN');
      reader.select('SELECT count(*) FROM entries');
      change(m, 2);
      sync.fail = true;
      expect(m.commitPoint, throwsA(isA<FileSystemException>()));
      expect(m.groupingDisabled, isTrue);
      expect(m.unflushedCommits, greaterThan(0), reason: 'still pending');
      reader.execute('COMMIT');
      m.commitPoint();
      expect(m.unflushedCommits, 0);
    } finally {
      reader.close();
      m.close();
    }
  });

  test('a pass ends at a commit point; every commit was ordered', () async {
    final sync = _Recorder();
    final parent = Directory('${fixture.path}/files')..createSync();
    final tree = RootTree.setup(parent.path, 'r', NativeRootFs());
    final store = Manifest(profile(), durability: sync)
      ..setSetting('retention', 'local');
    final cloud = FakeCloud();
    final engine = SyncEngine(store, tree, cloud);
    try {
      await engine.tick();
      tree.ensureDirectory('D');
      for (var i = 0; i < 100; i++) {
        File('${tree.root.path}/D/f$i.txt').writeAsStringSync('x $i');
      }
      for (var i = 0; i < 30; i++) {
        cloud.put('R/r$i.txt', 'remote $i');
      }
      final barriers = store.barriers, flushes = store.flushes;
      await engine.tick();
      final commits = engine.lastPass!.transactions;
      final newBarriers = store.barriers - barriers;
      final newFlushes = store.flushes - flushes;
      expect(cloud.files.keys.where((k) => k.startsWith('D/')).length, 100);
      expect(
        utf8.decode(File('${tree.root.path}/R/r7.txt').readAsBytesSync()),
        'remote 7',
      );
      expect(store.unflushedCommits, 0, reason: 'the pass ended durably');
      // Each commit got a barrier or ended its group with a flush; commit
      // points before destructive changes add flushes (decision #137 (1)).
      expect(newBarriers, lessThanOrEqualTo(commits));
      expect(newBarriers + newFlushes, greaterThanOrEqualTo(commits));
      // ignore: avoid_print
      print(
        'SC-051 pass: $commits commits, $newBarriers barriers, '
        '$newFlushes flushes',
      );
    } finally {
      engine.close();
    }
  });
}
