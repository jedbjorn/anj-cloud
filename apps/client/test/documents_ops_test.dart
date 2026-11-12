// Spec #28 A5: the sync worker's side of the documents provider
// (DocumentsOps) against the real libanj_rootfs.so on the VM host and a fake cloud:
// confined opens with the open-descriptor registry and release guard,
// no-replace creates, renames and moves that the next pass reconciles,
// deletes, Cloud-only opens through a working copy, and decision #120 names.
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/documents_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/documents_ops.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/open_documents.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/library_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  late OpenDocuments registry;
  late DocumentsOps ops;
  var paused = false;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-documents-ops-');
    final parent = Directory('${fixture.path}/a')..createSync();
    tree = RootTree.setup(parent.path, 'a', NativeRootFs());
    store = Manifest(Directory('${fixture.path}/profile'));
    store.setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud);
    registry = OpenDocuments();
    paused = false;
    ops = DocumentsOps(engine, registry: registry, paused: () => paused);
  });
  tearDown(() {
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  File local(String path) => File('${tree.root.path}/$path');
  Matcher refused(String code) =>
      throwsA(isA<DocumentsFailure>().having((e) => e.code, 'code', code));
  String read(int fd) => File('/proc/self/fd/$fd').readAsStringSync();

  test(
    'opens a Local file read-only through the boundary and registers it',
    () async {
      tree.ensureDirectory('Music');
      local('Music/a.txt').writeAsStringSync('song');
      await engine.tick();
      final opened = await ops.open(
        path: 'Music/a.txt',
        write: false,
        token: 't1',
      );
      final fd = opened['fd'] as int;
      expect(read(fd), 'song');
      expect(registry.isPathOpen('Music/a.txt'), isTrue);
      tree.native.closeFd(fd);
      ops.closed('t1');
      expect(registry.length, 0);
    },
  );

  test('never follows a symlink and never leaves the root', () async {
    File('${fixture.path}/outside.txt').writeAsStringSync('outside');
    Link('${tree.root.path}/link.txt')
        .createSync('${fixture.path}/outside.txt');
    await expectLater(
      ops.open(path: 'link.txt', write: false, token: 't'),
      throwsA(isA<Object>()),
    );
    await expectLater(
      ops.open(path: '../outside.txt', write: false, token: 't'),
      throwsA(isA<Object>()),
    );
    expect(registry.length, 0);
  });

  test(
    'the registry refuses release while another app holds the file',
    () async {
      local('a.txt').writeAsStringSync('bytes');
      await engine.tick();
      final opened = await ops.open(path: 'a.txt', write: true, token: 't1');
      tree.native.closeFd(opened['fd'] as int); // the lease is not held here
      final guard = RegisteredReleaseGuard(engine.artifacts.native, registry);
      final info = guard.info(tree.fd, 'a.txt');
      expect(
        () => guard.guard(tree.fd, 'a.txt', info, links: 1),
        throwsA(isA<FileSystemException>()),
      );
      ops.closed('t1');
      final fd = guard.guard(tree.fd, 'a.txt', info, links: 1);
      guard.close(fd);
    },
  );

  test(
    'a written descriptor uploads after close through the next pass',
    () async {
      local('doc.txt').writeAsStringSync('one');
      await engine.tick();
      expect(String.fromCharCodes(cloud.files['doc.txt']!), 'one');
      final opened = await ops.open(path: 'doc.txt', write: true, token: 't1');
      final fd = opened['fd'] as int;
      File('/proc/self/fd/$fd').writeAsStringSync('two');
      tree.native.closeFd(fd);
      ops.closed('t1');
      await engine.tick();
      expect(String.fromCharCodes(cloud.files['doc.txt']!), 'two');
    },
  );

  /// A remote file that arrives in a Cloud folder stays Cloud-only.
  Future<void> cloudOnly(String folder, String name, String text) async {
    if (!Directory('${tree.root.path}/$folder').existsSync()) {
      tree.ensureDirectory(folder);
      await engine.tick();
      engine.setRetention(folder, Retention.cloud);
    }
    cloud.put('$folder/$name', text);
    await engine.tick();
    expect(local('$folder/$name').existsSync(), isFalse);
    expect(store.entries['$folder/$name']!.status, 'cloud-only');
  }

  test('a Cloud-only open downloads one working copy and reuses it', () async {
    await cloudOnly('Far', 'far.txt', 'remote');
    final first = await ops.open(
      path: 'Far/far.txt',
      write: false,
      token: 't1',
    );
    expect(read(first['fd'] as int), 'remote');
    tree.native.closeFd(first['fd'] as int);
    final downloads = cloud.completedDownloads;
    final second = await ops.open(
      path: 'Far/far.txt',
      write: false,
      token: 't2',
    );
    expect(read(second['fd'] as int), 'remote');
    tree.native.closeFd(second['fd'] as int);
    expect(cloud.completedDownloads, downloads);
    expect(
      store.operations.values.where((o) => o.kind == 'working'),
      hasLength(1),
    );
    expect(registry.isPathOpen('Far/far.txt'), isTrue);
    expect(
      local('Far/far.txt').existsSync(),
      isFalse,
      reason: 'retention kept',
    );
    ops.closed('t1');
    ops.closed('t2');
    // Paused: nothing is downloaded.
    await cloudOnly('Far', 'other.txt', 'x');
    paused = true;
    final before = cloud.completedDownloads;
    await expectLater(
      ops.open(path: 'Far/other.txt', write: false, token: 't3'),
      refused('paused'),
    );
    expect(cloud.completedDownloads, before);
  });

  test(
    'creates never replace, take a free name and follow decision #120',
    () async {
      tree.ensureDirectory('Docs');
      local('Docs/a.txt').writeAsStringSync('keep');
      await engine.tick();
      expect(ops.create('Docs', 'a.txt'), 'Docs/a (1).txt');
      expect(local('Docs/a.txt').readAsStringSync(), 'keep');
      expect(local('Docs/a (1).txt').lengthSync(), 0);
      expect(() => ops.create('Docs', 'CON.txt'), refused('refused'));
      expect(() => ops.create('Docs', 'a:b.txt'), refused('refused'));
      expect(() => ops.create('Docs', 'A.TXT'), refused('refused'));
      expect(() => ops.create('Docs', '../x'), refused('refused'));
      expect(ops.createFolder('Docs', 'Sub'), 'Docs/Sub');
      expect(Directory('${tree.root.path}/Docs/Sub').existsSync(), isTrue);
      await engine.tick();
      expect(cloud.files.containsKey('Docs/a (1).txt'), isTrue);
      expect(cloud.directories, contains('Docs/Sub'));
      paused = true;
      expect(() => ops.create('Docs', 'b.txt'), refused('paused'));
    },
  );

  test('a folder made through the provider takes children at once', () async {
    // Review F2: a Files-app folder-tree copy creates a folder, then its
    // children, before any pass records the folder.
    tree.ensureDirectory('Docs');
    await engine.tick();
    cloud.online = false; // nothing synchronizes meanwhile
    expect(ops.createFolder('Docs', 'New'), 'Docs/New');
    expect(store.entries.containsKey('Docs/New'), isFalse);
    expect(ops.create('Docs/New', 'x.txt'), 'Docs/New/x.txt');
    expect(ops.createFolder('Docs/New', 'Nested'), 'Docs/New/Nested');
    expect(ops.create('Docs/New/Nested', 'y.txt'), 'Docs/New/Nested/y.txt');
    // Every name, exclusion and no-replace rule still holds.
    expect(ops.create('Docs/New', 'x.txt'), 'Docs/New/x (1).txt');
    expect(() => ops.create('Docs/New', 'CON'), refused('refused'));
    expect(() => ops.create('Docs/Missing', 'z.txt'), refused('notFound'));
    local('Docs/plain.txt').writeAsStringSync('f');
    expect(() => ops.create('Docs/plain.txt', 'z.txt'), refused('notFound'));
    cloud.online = true;
    await engine.tick();
    await engine.tick();
    expect(cloud.directories, contains('Docs/New/Nested'));
    expect(cloud.files.containsKey('Docs/New/Nested/y.txt'), isTrue);
  });

  test('Documents, Music and Videos are never deleted, renamed or moved '
      '(spec #34 P7)', () async {
    tree.ensureDirectory('Music');
    local('Music/a.txt').writeAsStringSync('song');
    await engine.tick();
    expect(() => ops.delete('Music'), refused('refused'));
    expect(() => ops.relocate('Music', '', 'Songs'), refused('refused'));
    expect(
      () => ops.relocate('Music', 'Documents', 'Music'),
      refused('refused'),
    );
    expect(local('Music/a.txt').readAsStringSync(), 'song');
    // Inside them, as anywhere else.
    expect(ops.relocate('Music/a.txt', 'Music', 'b.txt'), 'Music/b.txt');
    ops.delete('Music/b.txt');
    await engine.tick();
    await engine.tick();
    expect(cloud.files.containsKey('Music/b.txt'), isFalse);
    expect(Directory('${tree.root.path}/Music').existsSync(), isTrue);
  });

  test('rename of a synchronized file moves it in the cloud', () async {
    local('old.txt').writeAsStringSync('content');
    await engine.tick();
    expect(cloud.files.containsKey('old.txt'), isTrue);
    expect(ops.relocate('old.txt', '', 'new.txt'), 'new.txt');
    expect(local('old.txt').existsSync(), isFalse);
    await engine.tick();
    await engine.tick();
    expect(cloud.files.containsKey('old.txt'), isFalse);
    expect(String.fromCharCodes(cloud.files['new.txt']!), 'content');
    expect(local('old.txt').existsSync(), isFalse);
    expect(local('new.txt').readAsStringSync(), 'content');
  });

  test(
    'move of a folder carries its files; no replace, no self-move',
    () async {
      tree.ensureDirectory('A/Inner');
      tree.ensureDirectory('B');
      local('A/Inner/x.txt').writeAsStringSync('x');
      local('B/Inner').createSync();
      await engine.tick();
      expect(() => ops.relocate('A/Inner', 'B', 'Inner'), refused('exists'));
      expect(() => ops.relocate('A', 'A/Inner', 'A'), refused('refused'));
      expect(ops.relocate('A/Inner', '', 'Inner'), 'Inner');
      await engine.tick();
      await engine.tick();
      expect(String.fromCharCodes(cloud.files['Inner/x.txt']!), 'x');
      expect(cloud.files.containsKey('A/Inner/x.txt'), isFalse);
      expect(File('${tree.root.path}/A/Inner/x.txt').existsSync(), isFalse);
    },
  );

  test('a folder holding a Cloud-only file is not moved', () async {
    await cloudOnly('Box', 'far.txt', 'remote');
    expect(() => ops.relocate('Box', '', 'Crate'), refused('refused'));
    expect(
      () => ops.relocate('Box/far.txt', '', 'far.txt'),
      refused('refused'),
    );
  });

  test(
    'deletes: synchronized ones propagate, unsynchronized ones are removed',
    () async {
      local('synced.txt').writeAsStringSync('s');
      await engine.tick();
      ops.delete('synced.txt');
      await engine.tick();
      expect(cloud.files.containsKey('synced.txt'), isFalse);
      expect(local('synced.txt').existsSync(), isFalse);
      // Never synchronized (offline): removed locally under the guard, with
      // nothing left in staging.
      cloud.online = false;
      local('fresh.txt').writeAsStringSync('f');
      await engine.tick();
      final staged = tree.staging.listSync().length;
      ops.delete('fresh.txt');
      expect(local('fresh.txt').existsSync(), isFalse);
      expect(tree.staging.listSync().length, staged);
      expect(
        store.operations.values.where((o) => o.data['role'] == 'discard'),
        isEmpty,
      );
      tree.ensureDirectory('Fresh');
      local('Fresh/f.txt').writeAsStringSync('f');
      await engine.tick();
      expect(() => ops.delete('Fresh'), refused('refused'));
      // Open in another app: refused, and the bytes stay.
      final opened = await ops.open(
        path: 'Fresh/f.txt',
        write: false,
        token: 't',
      );
      expect(() => ops.delete('Fresh/f.txt'), refused('busy'));
      tree.native.closeFd(opened['fd'] as int);
      ops.closed('t');
      ops.delete('Fresh/f.txt');
      ops.delete('Fresh');
      expect(Directory('${tree.root.path}/Fresh').existsSync(), isFalse);
    },
  );

  test(
    'Finish editing of a provider-opened copy waits for the app to close it',
    () async {
      await cloudOnly('Far', 'doc.txt', 'draft');
      final opened = await ops.open(
        path: 'Far/doc.txt',
        write: true,
        token: 't1',
      );
      final fd = opened['fd'] as int;
      // The app's own read-write descriptor (the runner reopens it this way).
      final app = File('/proc/self/fd/$fd').openSync(mode: FileMode.append);
      tree.native.closeFd(fd);
      app.writeStringSync(' edited');
      app.flushSync();
      engine.editing.request(
        'Far/doc.txt',
        engine.workingCopies('Far/doc.txt').cast(),
      );
      await engine.tick();
      await engine.tick();
      expect(
        engine.workingCopies('Far/doc.txt'),
        isNotEmpty,
        reason: 'still open',
      );
      app.closeSync();
      ops.closed('t1');
      engine.editing.request(
        'Far/doc.txt',
        engine.workingCopies('Far/doc.txt').cast(),
      );
      for (var i = 0; i < 4; i++) {
        await engine.tick();
      }
      expect(String.fromCharCodes(cloud.files['Far/doc.txt']!), 'draft edited');
      expect(engine.workingCopies('Far/doc.txt'), isEmpty);
      expect(
        local('Far/doc.txt').existsSync(),
        isFalse,
        reason: 'Cloud retention kept',
      );
    },
  );
  // Decision #183 (narrows #108 Q10): opening is not editing.
  Future<Map<String, dynamic>> row(String path) async =>
      Map<String, dynamic>.from(
        await projectEntry(engine, store.entries[path]!),
      );
  Iterable<Operation> sessions() =>
      store.operations.values.where((o) => o.kind == 'working');
  Iterable<String> stagedWorking() => tree.staging
      .listSync()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.startsWith('working-'));

  test('an opened, unchanged copy is not Editing and the next pass reclaims '
      'it once closed', () async {
    await cloudOnly('Far', 'song.txt', 'tune');
    engine.workingCopyGrace = Duration.zero;
    final opened = await ops.open(
      path: 'Far/song.txt',
      write: false,
      token: 't1',
    );
    expect(read(opened['fd'] as int), 'tune');
    tree.native.closeFd(opened['fd'] as int);
    var projected = await row('Far/song.txt');
    expect((projected['workingCopies'] as List).single['edited'], isFalse);
    expect(editedCopies(projected), isEmpty, reason: 'no Finish editing');
    expect(hasEditing(projected), isFalse);
    expect(fileBadge(projected), 'Cloud');
    expect(librarySummary(projected), isNot(contains('editing')));
    // Nothing for an update to wait on (the worker's `finishing`).
    expect(engine.editing.requests, isEmpty);
    ops.closed('t1');
    await engine.tick();
    expect(sessions(), isEmpty);
    expect(stagedWorking(), isEmpty);
    expect(
      store.operations.values.where((o) => o.data['role'] == 'working'),
      isEmpty,
    );
    expect(store.entries['Far/song.txt']!.status, 'cloud-only');
    expect(store.entries['Far/song.txt']!.workingCopy, isNull);
    expect(String.fromCharCodes(cloud.files['Far/song.txt']!), 'tune');
    projected = await row('Far/song.txt');
    expect(fileBadge(projected), 'Cloud');
    expect(engine.editing.requests, isEmpty);
  });

  test('an opened copy that was written is Editing with Finish editing, as '
      'before', () async {
    await cloudOnly('Far', 'doc.txt', 'draft');
    engine.workingCopyGrace = Duration.zero;
    final opened = await ops.open(
      path: 'Far/doc.txt',
      write: true,
      token: 't1',
    );
    final fd = opened['fd'] as int;
    final app = File('/proc/self/fd/$fd').openSync(mode: FileMode.append);
    tree.native.closeFd(fd);
    app.writeStringSync(' edited');
    app.closeSync();
    ops.closed('t1');
    await engine.tick();
    await engine.tick();
    expect(String.fromCharCodes(cloud.files['Far/doc.txt']!), 'draft edited');
    expect(sessions(), hasLength(1), reason: 'kept for Finish editing');
    expect(sessions().single.data['edited'], isTrue);
    final projected = await row('Far/doc.txt');
    expect(editedCopies(projected), hasLength(1));
    expect(fileBadge(projected), 'Editing');
    engine.editing.request(
      'Far/doc.txt',
      engine.workingCopies('Far/doc.txt').cast(),
    );
    await engine.tick();
    await engine.tick();
    expect(sessions(), isEmpty);
    expect(stagedWorking(), isEmpty);
    expect(String.fromCharCodes(cloud.files['Far/doc.txt']!), 'draft edited');
  });

  test('an unchanged copy an app still holds open is not reclaimed', () async {
    await cloudOnly('Far', 'film.txt', 'frames');
    engine.workingCopyGrace = Duration.zero;
    final opened = await ops.open(
      path: 'Far/film.txt',
      write: false,
      token: 't1',
    );
    final fd = opened['fd'] as int;
    // The app's own descriptor (the runner reopens it this way).
    final app = File('/proc/self/fd/$fd').openSync();
    tree.native.closeFd(fd);
    await engine.tick();
    await engine.tick();
    expect(sessions(), hasLength(1), reason: 'still open');
    expect(stagedWorking(), hasLength(1));
    expect(fileBadge(await row('Far/film.txt')), 'Cloud');
    expect(app.readSync(6), 'frames'.codeUnits);
    app.closeSync();
    ops.closed('t1');
    await engine.tick();
    expect(sessions(), isEmpty);
    expect(stagedWorking(), isEmpty);
  });

  test('a reopen reuses the unchanged copy while it exists; a just-opened '
      'copy is kept for its app', () async {
    await cloudOnly('Far', 'track.txt', 'notes');
    var shift = Duration.zero;
    final clock = Stopwatch()..start();
    engine.debugElapsed = () => clock.elapsed + shift;
    final first = await ops.open(
      path: 'Far/track.txt',
      write: false,
      token: 't1',
    );
    tree.native.closeFd(first['fd'] as int);
    ops.closed('t1');
    await engine.tick();
    expect(sessions(), hasLength(1), reason: 'within the grace');
    final downloads = cloud.completedDownloads;
    final second = await ops.open(
      path: 'Far/track.txt',
      write: false,
      token: 't2',
    );
    expect(read(second['fd'] as int), 'notes');
    tree.native.closeFd(second['fd'] as int);
    ops.closed('t2');
    expect(cloud.completedDownloads, downloads, reason: 'reused');
    expect(sessions(), hasLength(1));
    shift = engine.workingCopyGrace;
    await engine.tick();
    expect(sessions(), isEmpty);
    expect(stagedWorking(), isEmpty);
  });
  test('a copy handed out as a plain path (desktop Open) is never cleared '
      'automatically; once written it is Editing (decision #184)', () async {
    await cloudOnly('Far', 'notes.txt', 'plain');
    var shift = Duration.zero;
    final clock = Stopwatch()..start();
    engine.debugElapsed = () => clock.elapsed + shift;
    // What the worker's Open does where the launcher hands out the path.
    final staged = File(await engine.openFile('Far/notes.txt'));
    expect(sessions().single.data['handout'], 'untracked');
    shift = engine.workingCopyGrace * 2;
    await engine.tick();
    await engine.tick();
    expect(sessions(), hasLength(1), reason: 'never reclaimed');
    expect(staged.readAsStringSync(), 'plain');
    var projected = await row('Far/notes.txt');
    expect(hasEditing(projected), isFalse);
    expect(editedCopies(projected), isEmpty);
    expect(fileBadge(projected), 'Cloud');
    // The editor saves later, after closing the file long ago.
    staged.writeAsStringSync('plain, edited', flush: true);
    await engine.tick();
    expect(
      String.fromCharCodes(cloud.files['Far/notes.txt']!),
      'plain, edited',
    );
    projected = await row('Far/notes.txt');
    expect(editedCopies(projected), hasLength(1), reason: 'Finish editing');
    expect(fileBadge(projected), 'Editing');
    await engine.tick();
    expect(sessions(), hasLength(1));
  });
}
