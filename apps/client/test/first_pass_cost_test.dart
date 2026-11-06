import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// First-pass cost (flag SC-057, spec #33 I4): rows that only record the
/// cloud share commits; every other row keeps its own.
void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  var closed = false;

  setUp(() async {
    closed = false;
    fixture = Directory.systemTemp.createTempSync('anj-first-pass-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'first-pass', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
    tree.ensureDirectory('Photos');
    tree.ensureDirectory('Local');
    await engine.tick();
    engine.setRetention('Photos', Retention.cloud);
    await engine.tick();
  });
  tearDown(() {
    if (closed) {
      store.close();
    } else {
      engine.close();
    }
    fixture.deleteSync(recursive: true);
  });

  void library(int files) {
    for (var d = 0; d < files ~/ 100; d++) {
      cloud.directories.add('Photos/d$d');
      cloud.versions['Photos/d$d'] = '"d$d"';
      for (var f = 0; f < 100; f++) {
        cloud.put('Photos/d$d/f$f.jpg', 'x');
      }
    }
  }

  Manifest reopen() {
    engine.close();
    closed = true;
    store = Manifest(store.profile);
    return store;
  }

  test(
    'Cloud-only rows share commits and are all durable at the pass end',
    () async {
      library(2000);
      final before = store.transactions;
      await engine.tick();
      final commits = store.transactions - before;
      expect(
        commits,
        lessThanOrEqualTo(2020 ~/ SyncEngine.listingOnlyCommit + 2),
      );
      final reopened = reopen();
      for (var d = 0; d < 20; d++) {
        for (var f = 0; f < 100; f++) {
          final entry = reopened.entries['Photos/d$d/f$f.jpg'];
          expect(entry?.etag, cloud.versions['Photos/d$d/f$f.jpg']);
          expect(entry?.status, 'cloud-only');
          expect(entry?.expectedPresent, false);
        }
      }
      expect(Directory('${tree.root.path}/Photos/d0').existsSync(), false);
    },
  );

  test('a pass stopped early keeps every row it recorded', () async {
    library(1000);
    var visited = 0;
    await engine.tick(
      between: () async {
        if (++visited == 600) engine.stopRequested = true;
        return false;
      },
    );
    final recorded = store.entries.keys
        .where((path) => store.entries[path]!.status == 'cloud-only')
        .toSet();
    expect(recorded.length, greaterThan(400));
    final reopened = reopen();
    for (final path in recorded) {
      expect(reopened.entries[path]?.status, 'cloud-only', reason: path);
    }
  });

  test(
    'only a row with nothing on disk and nothing in flight shares a commit',
    () {
      const path = 'Photos/a.jpg';
      final entry = Entry(path, ItemKind.file)
        ..etag = '"1"'
        ..status = 'cloud-only';
      store.entries[path] = entry;
      bool shares({LocalItem? here, bool failed = false}) =>
          engine.listingOnlyRow(entry, here: here, failed: failed);
      expect(shares(), isTrue);
      // On disk.
      expect(shares(here: const LocalItem(path, ItemKind.file)), isFalse);
      // Expected on disk (a download or a Local choice).
      entry.expectedPresent = true;
      expect(shares(), isFalse);
      entry.expectedPresent = false;
      // Work in flight.
      final op = engine.intent(path, 'evict', etag: '"1"');
      expect(shares(), isFalse);
      store.operations.remove(op.id);
      // A conflict, or a visit that failed.
      entry.conflict = 'both changed';
      expect(shares(), isFalse);
      entry.conflict = null;
      expect(shares(failed: true), isFalse);
      expect(shares(), isTrue);
    },
  );

  test('a crash that loses the open group: rows return from the next listing, nothing inferred', () async {
    library(1000);
    final profile = store.profile;
    final crash = Directory('${fixture.path}/crash');
    var visited = 0;
    // The on-disk manifest as a crash at this point would leave it: the
    // database and its WAL, copied between two paths of the pass.
    await engine.tick(
      between: () async {
        if (++visited == 700) {
          crash.createSync();
          for (final name in ['manifest.sqlite', 'manifest.sqlite-wal']) {
            final file = File('${profile.path}/$name');
            if (file.existsSync()) file.copySync('${crash.path}/$name');
          }
        }
        return false;
      },
    );
    expect(
      store.entries.values.where((e) => e.status == 'cloud-only').length,
      1010,
    );
    engine.close();
    closed = true;
    for (final name in [
      'manifest.sqlite',
      'manifest.sqlite-wal',
      'manifest.sqlite-shm',
    ]) {
      final file = File('${profile.path}/$name');
      if (file.existsSync()) file.deleteSync();
    }
    for (final file in crash.listSync().whereType<File>()) {
      file.copySync('${profile.path}/${file.uri.pathSegments.last}');
    }
    store = Manifest(profile);
    final survived = store.entries.values
        .where((e) => e.path.startsWith('Photos/d'))
        .length;
    // The open group was lost: some rows are missing, none are corrupt.
    expect(survived, lessThan(700));
    expect(survived, greaterThan(0));
    expect(store.operations, isEmpty);
    final before = Map.of(cloud.versions);
    tree = RootTree(tree.root, tree.staging, NativeRootFs());
    engine = SyncEngine(store, tree, cloud);
    closed = false;
    await engine.tick();
    expect(engine.remoteListed, isTrue, reason: engine.message);
    for (var d = 0; d < 10; d++) {
      for (var f = 0; f < 100; f++) {
        final entry = store.entries['Photos/d$d/f$f.jpg'];
        expect(entry?.status, 'cloud-only', reason: 'Photos/d$d/f$f.jpg');
        expect(entry?.etag, cloud.versions['Photos/d$d/f$f.jpg']);
      }
    }
    // Nothing inferred: no cloud change, no operation, nothing on disk.
    expect(cloud.versions, before);
    expect(cloud.deletes + cloud.uploads + cloud.completedDownloads, 0);
    expect(store.operations, isEmpty);
    expect(Directory('${tree.root.path}/Photos/d0').existsSync(), isFalse);
  });

  test('a downloaded file still commits on its own', () async {
    for (var f = 0; f < 20; f++) {
      cloud.put('Local/f$f.txt', 'local $f');
    }
    final before = store.transactions;
    await engine.tick();
    expect(store.transactions - before, greaterThanOrEqualTo(20));
    expect(
      File('${tree.root.path}/Local/f7.txt').readAsStringSync(),
      'local 7',
    );
  });
}
