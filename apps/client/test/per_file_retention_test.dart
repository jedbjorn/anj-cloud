// Per-file Cloud-only (spec #45): a file's own storage choice beats its
// folder's (R1); a folder's choice clears the own choices of the files that
// inherit from it (R2); Select mode takes files, folders or a mix (R4); and
// every release guard still holds, with the row saying why (R5).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/library_view.dart';

import 'fakes.dart';

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-per-file-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'per-file', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });
  File local(String path) => File('${tree.root.path}/$path');
  void write(String path, String text) => (local(
    path,
  )..parent.createSync(recursive: true)).writeAsStringSync(text, flush: true);
  String digest(List<int> bytes) => sha256.convert(bytes).toString();
  Retention? own(String path) => store.entries[path]!.override;
  Future<Map<String, dynamic>> row(String path) async =>
      Map<String, dynamic>.from(
        await projectEntry(engine, store.entries[path]!),
      );
  void reopen() {
    final root = tree.root.path;
    final staging = tree.staging.path;
    final profile = store.profile;
    engine.close();
    store = Manifest(profile);
    tree = RootTree(Directory(root), Directory(staging), NativeRootFs());
    engine = SyncEngine(store, tree, cloud);
  }

  Future<void> synced(Map<String, String> files) async {
    files.forEach(write);
    await engine.tick();
    for (final path in files.keys) {
      expect(store.entries[path]!.etag, isNotNull, reason: path);
    }
  }

  group('precedence and clearing (F2)', () {
    test("a file's own choice beats its folder's both ways and survives a "
        'restart', () async {
      await synced({
        'Library/a.txt': 'alpha',
        'Library/b.txt': 'beta',
        'Archive/c.txt': 'gamma',
      });
      engine.setRetention('Archive', Retention.cloud);
      await engine.tick();
      expect(local('Archive/c.txt').existsSync(), isFalse);

      engine.setRetention('Library/a.txt', Retention.cloud);
      engine.setRetention('Archive/c.txt', Retention.local);
      expect(engine.retention('Library/a.txt'), Retention.cloud);
      expect(engine.retention('Library/b.txt'), Retention.local);
      expect(engine.retention('Archive/c.txt'), Retention.local);
      await engine.tick();
      await engine.tick();
      expect(local('Library/a.txt').existsSync(), isFalse);
      expect(store.entries['Library/a.txt']!.status, 'cloud-only');
      expect(local('Library/b.txt').readAsStringSync(), 'beta');
      expect(local('Archive/c.txt').readAsStringSync(), 'gamma');
      expect(cloud.deletes, 0);

      reopen();
      expect(own('Library/a.txt'), Retention.cloud);
      expect(own('Archive/c.txt'), Retention.local);
      expect(engine.retention('Library/a.txt'), Retention.cloud);
      expect(engine.retention('Archive/c.txt'), Retention.local);
    });

    test(
      'choosing what the folder gives drops the own choice (as folder)',
      () async {
        await synced({'Library/a.txt': 'alpha'});
        engine.setRetention('Library/a.txt', Retention.cloud);
        expect(own('Library/a.txt'), Retention.cloud);
        expect((await row('Library/a.txt'))['override'], 'cloud');
        engine.setRetention('Library/a.txt', Retention.local);
        expect(own('Library/a.txt'), isNull);
        final projected = await row('Library/a.txt');
        expect(projected['override'], isNull);
        expect(projected['effectiveRetention'], 'local');
      },
    );

    test('a folder choice clears the files that inherit from it; nested '
        'folder choices and their files stay', () async {
      await synced({
        'Library/a.txt': 'a',
        'Library/Inner/i.txt': 'i',
        'Library/Nested/n.txt': 'n',
      });
      engine.setRetention('Library/Nested', Retention.local);
      engine.setRetention('Library/a.txt', Retention.cloud);
      engine.setRetention('Library/Inner/i.txt', Retention.cloud);
      engine.setRetention('Library/Nested/n.txt', Retention.cloud);
      engine.setRetention('Library', Retention.local);
      expect(own('Library/a.txt'), isNull);
      expect(own('Library/Inner/i.txt'), isNull);
      expect(own('Library/Nested'), Retention.local);
      expect(own('Library/Nested/n.txt'), Retention.cloud);

      // Cloud-only on a folder means everything it governs.
      engine.setRetention('Library/a.txt', Retention.local);
      expect(own('Library/a.txt'), isNull);
      engine.setRetention('Library/Inner/i.txt', Retention.local);
      engine.setRetention('Library', Retention.cloud);
      expect(own('Library/Inner/i.txt'), isNull);
      await engine.tick();
      await engine.tick();
      expect(local('Library/a.txt').existsSync(), isFalse);
      expect(local('Library/Inner/i.txt').existsSync(), isFalse);
      expect(local('Library/Nested/n.txt').existsSync(), isFalse);
      expect(own('Library/Nested'), Retention.local);
    });

    test('a top folder clears its loose files only; its folders keep their '
        'state (#97 N2) and their files their choice', () async {
      await synced({'Music/loose.mp3': 'loose', 'Music/Album/a.flac': 'album'});
      engine.setRetention('Music/loose.mp3', Retention.cloud);
      engine.setRetention('Music/Album/a.flac', Retention.cloud);
      expect(store.entries['Music']!.override, isNull);

      engine.setRetention('Music', Retention.cloud);
      expect(own('Music/Album'), Retention.local);
      expect(own('Music/loose.mp3'), isNull);
      expect(own('Music/Album/a.flac'), Retention.cloud);
      expect(engine.retention('Music/loose.mp3'), Retention.cloud);
      expect(engine.retention('Music/Album/x.flac'), Retention.local);
      // Music itself stays on the device (spec #34 P7).
      expect(engine.retention('Music'), Retention.local);
      await engine.tick();
      await engine.tick();
      expect(local('Music/loose.mp3').existsSync(), isFalse);
      expect(local('Music/Album/a.flac').existsSync(), isFalse);
      expect(Directory('${tree.root.path}/Music').existsSync(), isTrue);
    });

    test('Select mode takes files, folders and a mix; one refused target '
        'changes nothing', () async {
      await synced({
        'Library/a.txt': 'a',
        'Library/b.txt': 'b',
        'Photos/p.jpg': 'p',
      });
      Map<String, dynamic> target(String path) => {
        'path': path,
        'kind': store.entries[path]!.kind.name,
        'selectionVersion': engine.selectionVersion(store.entries[path]!),
      };
      final refused = engine.applyBulk('cloud', [
        target('Library/a.txt'),
        {...target('Photos'), 'selectionVersion': 'stale'},
      ]);
      expect(refused['accepted'], 0);
      expect(own('Library/a.txt'), isNull);

      final mixed = engine.applyBulk('cloud', [
        target('Library/a.txt'),
        target('Photos'),
        target('Photos/p.jpg'),
      ]);
      expect(mixed['accepted'], 3);
      expect(engine.retention('Library/a.txt'), Retention.cloud);
      expect(engine.retention('Library/b.txt'), Retention.local);
      expect(own('Photos'), Retention.cloud);
      // The file follows its selected folder.
      expect(own('Photos/p.jpg'), isNull);
      await engine.tick();
      await engine.tick();
      expect(local('Library/a.txt').existsSync(), isFalse);
      expect(local('Library/b.txt').existsSync(), isTrue);
      expect(local('Photos/p.jpg').existsSync(), isFalse);

      final back = engine.applyBulk('local', [target('Library/a.txt')]);
      expect(back['accepted'], 1);
      await engine.tick();
      expect(local('Library/a.txt').readAsStringSync(), 'a');
    });
  });

  test('one loose song in Music becomes Cloud-only and Keep brings it back '
      'unchanged (F1, engine)', () async {
    await synced({'Music/one.mp3': 'first song', 'Music/two.mp3': 'second'});
    final hash = digest(local('Music/one.mp3').readAsBytesSync());
    final other = local('Music/two.mp3').statSync();
    engine.setRetention('Music/one.mp3', Retention.cloud);
    expect((await row('Music/one.mp3'))['effectiveRetention'], 'cloud');
    await engine.tick();
    await engine.tick();
    expect(local('Music/one.mp3').existsSync(), isFalse);
    final released = await row('Music/one.mp3');
    expect(released['status'], 'cloud-only');
    expect(fileBadge(released), 'Cloud');
    expect(local('Music/two.mp3').statSync().modified, other.modified);
    expect((await row('Music/two.mp3'))['effectiveRetention'], 'local');
    expect(digest(cloud.files['Music/one.mp3']!), hash);
    expect(cloud.deletes, 0);

    engine.setRetention('Music/one.mp3', Retention.local);
    await engine.tick();
    expect(digest(local('Music/one.mp3').readAsBytesSync()), hash);
    expect(fileBadge(await row('Music/one.mp3')), 'Local');
  });

  group("a deleted file's choice ends with it", () {
    test(
      'deleted here: a new file at the same path follows its folder',
      () async {
        await synced({'Library/song.mp3': 'old song'});
        engine.setRetention('Library/song.mp3', Retention.cloud);
        await engine.tick();
        expect(local('Library/song.mp3').existsSync(), isFalse);
        engine.requestDelete('Library/song.mp3');
        await engine.tick();
        expect(store.entries['Library/song.mp3']!.status, 'deleted');
        expect(own('Library/song.mp3'), isNull);

        write('Library/song.mp3', 'new song');
        await engine.tick();
        await engine.tick();
        expect(
          String.fromCharCodes(cloud.files['Library/song.mp3']!),
          'new song',
        );
        expect(local('Library/song.mp3').readAsStringSync(), 'new song');
        expect(engine.retention('Library/song.mp3'), Retention.local);
        reopen();
        expect(own('Library/song.mp3'), isNull);
      },
    );

    test('deleted in the cloud: a new file there downloads under a Local '
        'folder', () async {
      await synced({'Library/song.mp3': 'old song'});
      engine.setRetention('Library/song.mp3', Retention.cloud);
      await engine.tick();
      expect(local('Library/song.mp3').existsSync(), isFalse);
      cloud.remove('Library/song.mp3');
      await engine.tick();
      expect(store.entries['Library/song.mp3']!.status, 'deleted remotely');
      expect(own('Library/song.mp3'), isNull);

      cloud.put('Library/song.mp3', 'new song');
      await engine.tick();
      await engine.tick();
      expect(local('Library/song.mp3').readAsStringSync(), 'new song');
      expect(engine.retention('Library/song.mp3'), Retention.local);
    });
  });

  group('the release guards hold (F3)', () {
    test('a file held open is released only after it is closed', () async {
      await synced({'Library/song.mp3': 'song'});
      engine.setRetention('Library/song.mp3', Retention.cloud);
      final held = local('Library/song.mp3').openSync();
      try {
        await engine.tick();
        expect(local('Library/song.mp3').existsSync(), isTrue);
        final projected = await row('Library/song.mp3');
        expect(projected['releaseNote'], freesWhenClosed);
        expect(librarySummary(projected), contains(freesWhenClosed));
      } finally {
        held.closeSync();
      }
      await engine.tick();
      expect(local('Library/song.mp3').existsSync(), isFalse);
      expect((await row('Library/song.mp3'))['releaseNote'], isNull);
      expect(cloud.deletes, 0);
    });

    test('a file not yet uploaded is released only after its upload', () async {
      cloud.failUpload = true;
      write('Library/new.mp3', 'new song');
      await engine.tick();
      expect(store.entries['Library/new.mp3']!.etag, isNull);
      engine.setRetention('Library/new.mp3', Retention.cloud);
      await engine.tick();
      expect(local('Library/new.mp3').readAsStringSync(), 'new song');
      final waiting = await row('Library/new.mp3');
      expect(waiting['releaseNote'], freesAfterUpload);
      expect(librarySummary(waiting), contains(freesAfterUpload));
      expect(cloud.files.containsKey('Library/new.mp3'), isFalse);

      cloud.failUpload = false;
      engine.uploads.retryAll();
      await engine.tick();
      await engine.tick();
      expect(String.fromCharCodes(cloud.files['Library/new.mp3']!), 'new song');
      expect(local('Library/new.mp3').existsSync(), isFalse);
      expect((await row('Library/new.mp3'))['releaseNote'], isNull);
    });

    test('a file in conflict is not released; resolved, it is', () async {
      await synced({'Library/doc.txt': 'base'});
      write('Library/doc.txt', 'local edit');
      cloud.put('Library/doc.txt', 'remote edit');
      await engine.tick();
      expect(store.entries['Library/doc.txt']!.conflict, isNotNull);
      engine.setRetention('Library/doc.txt', Retention.cloud);
      await engine.tick();
      expect(local('Library/doc.txt').readAsStringSync(), 'local edit');
      expect((await row('Library/doc.txt'))['releaseNote'], freesAfterConflict);

      await engine.keepBoth('Library/doc.txt');
      await engine.tick();
      await engine.tick();
      expect(store.entries['Library/doc.txt']!.conflict, isNull);
      expect(local('Library/doc.txt').existsSync(), isFalse);
      expect(
        String.fromCharCodes(cloud.files['Library/doc.txt']!),
        'remote edit',
      );
      // The local edit stays as a new file under its folder's choice.
      final kept = store.entries.keys.singleWhere(
        (path) => path.startsWith('Library/doc.txt.conflict-'),
      );
      expect(local(kept).readAsStringSync(), 'local edit');
    });
  });
}
