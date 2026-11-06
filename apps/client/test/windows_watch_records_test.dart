// Spec #32 "File Watching" on the VM host: the Windows watcher's Dart side without
// Windows. native/windows/watch_translate.h turns ReadDirectoryChangesW
// notifications into the shared compact records on the root's descriptor,
// with the whole root-relative path as the name (its own table is tested by
// tool/test_windows_watch.sh); here those records are fed to the shared
// LocalWatcher (over inotify) and the engine, and the Windows factory's
// selection, wiring and fallback run over the Linux library with an NTFS
// filesystem reported. The watch itself, with a 5,000-file burst, a forced
// overflow and a failing watch handle, is proven on W10C-Testing
// (native/windows/test/rootfs_win_test.cc).
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'test_platform.dart';

// The inotify mask bits the translator emits.
const inModify = 0x2;
const inMovedFrom = 0x40;
const inMovedTo = 0x80;
const inCreate = 0x100;
const inMoveSelf = 0x800;
const inIsDir = 0x40000000;

/// The shared binding as the Windows adapter constructs it (the 60-minute
/// verification interval), over the Linux library, reporting NTFS.
class _Ntfs extends NativeRootFs {
  _Ntfs({this.magic = WindowsChangeWatchers.ntfsMagic, this.queryFails = false})
    : super(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
        'Linux errno',
        windowsFullVerificationInterval,
      );
  final int magic;
  final bool queryFails;
  @override
  int fsMagic(int fd, String path) {
    if (queryFails) throw const FileSystemException('volume query refused');
    return magic;
  }
}

/// What watch_translate.h emits, all on the root's descriptor.
class FakeReadDirectoryChanges {
  FakeReadDirectoryChanges(this.watcher);
  final LocalWatcher watcher;
  int get _root => watcher.debugWatchDescriptor('')!;
  void send(List<Object> records) {
    watcher.handleRecords(records);
    watcher.onChange?.call();
  }

  void modified(String path) => send([_root, inModify, 0, path]);
  void folderAdded(String path) => send([_root, inCreate | inIsDir, 0, path]);
  void renamed(String from, String to, {bool folder = false}) => send([
    _root, inMovedFrom | (folder ? inIsDir : 0), 7, from, //
    _root, inMovedTo | (folder ? inIsDir : 0), 7, to,
  ]);

  /// An 8.3 or unreadable name at the top: a stat audit of the root.
  void rootAudit() => send([_root, inCreate | inIsDir, 0, '']);
  void overflow() => send([-1, inQueueOverflow, 0, '']);
  void watchFailed() => send([_root, inMoveSelf, 0, '']);
  void suspend() => send([-2, 0, 0, '']);
}

void main() {
  late Directory fixture;
  late RootTree tree;
  late Manifest store;
  late FakeCloud cloud;
  late SyncEngine engine;
  late File outside;
  const path = 'Documents/sub/linked.txt';

  LocalWatcher watcher() => engine.watcher! as LocalWatcher;
  File local(String p) => File('${tree.root.path}/$p');
  String? remote(String p) {
    final bytes = cloud.files[p];
    return bytes == null ? null : utf8.decode(bytes);
  }

  Future<void> pump(bool Function() done) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await engine.tick();
      if (done()) return;
      if (DateTime.now().isAfter(end)) fail('condition not reached');
    }
  }

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

  /// A write through a hard link outside the root: no event in the root, so
  /// only a record (or a verification) can bring it in.
  Future<void> silentEdit(String content) async {
    outside.writeAsStringSync(content, flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.tick();
    expect(remote(path), isNot(content), reason: 'the edit sent no event');
  }

  setUp(() async {
    WindowsChangeWatchers.debugFailWatch = false;
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-rdcw-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    // No trusted stamps (no writeback signal), as on NTFS.
    tree = RootTree.setup(parent.path, 'watch', _Ntfs())
      ..vmDirectory = '${fixture.path}/no-vm';
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    engine =
        SyncEngine(store, tree, cloud, watchers: const WindowsChangeWatchers())
          ..watcherSettings = const WatcherSettings(
            quiet: Duration(milliseconds: 150),
            maxDelay: Duration(seconds: 2),
          );
    await engine.startWatching();
    expect(engine.watcher, isNotNull);
    tree.ensureDirectory('Documents/sub');
    // Others a full verification would read too.
    for (var i = 0; i < 10; i++) {
      local('Documents/f$i.txt').writeAsStringSync('file $i');
    }
    local(path).writeAsStringSync('version 1');
    outside = File('${fixture.path}/outside-link');
    await Process.run('ln', [local(path).path, outside.path]);
    await pump(
      () => remote(path) == 'version 1' && remote('Documents/f9.txt') != null,
    );
    await quiesce();
  });
  tearDown(() {
    WindowsChangeWatchers.debugFailWatch = false;
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  // The records ride the inotify LocalWatcher over the Linux library.
  final overInotify = linuxOnly(
    'Windows records fed to the inotify LocalWatcher (Linux library)',
  );

  group('ReadDirectoryChangesW records drive the shared watcher', () {
    test('event-driven: a nested path on the root descriptor is the only '
        'file read', () async {
      expect(engine.eventDriven, isTrue);
      await silentEdit('version 2');
      final scans = engine.fullScans;
      final verifications = engine.fullVerifications;
      FakeReadDirectoryChanges(watcher()).modified(path);
      await pump(() => remote(path) == 'version 2');
      // Only the hinted file is read (a full verification reads all 11).
      expect(engine.lastPass!.filesHashedBy['scan'] ?? 0, lessThanOrEqualTo(1));
      expect(engine.fullScans, scans);
      expect(engine.fullVerifications, verifications);
    });

    test('a new folder is a subtree record: everything beneath is read', () {
      final w = watcher();
      var now = 0;
      w.debugNow = () => now;
      FakeReadDirectoryChanges(w).folderAdded('Documents/New');
      // Later events beneath it are absorbed by the subtree entry.
      FakeReadDirectoryChanges(w).modified('Documents/New/a/b.txt');
      expect(w.pending.toList(), ['Documents/New']);
      now = const Duration(seconds: 5).inMicroseconds;
      final work = w.take();
      expect(work.subtrees, {'Documents/New'});
      expect(work.paths, isEmpty);
    });

    test('a rename is both sides, each re-read by stat', () {
      final w = watcher();
      var now = 0;
      w.debugNow = () => now;
      FakeReadDirectoryChanges(w)
          .renamed('Documents/a.txt', 'Documents/sub/b.txt');
      FakeReadDirectoryChanges(w).renamed('Old', 'New', folder: true);
      now = const Duration(seconds: 5).inMicroseconds;
      final work = w.take();
      expect(work.paths, {'Documents/a.txt', 'Documents/sub/b.txt'});
      expect(work.subtrees, {'Old', 'New'});
    });

    test('an 8.3 name at the top is a stat audit of the root: only the '
        'changed file is read, and no verification', () async {
      await silentEdit('version 2');
      final scans = engine.fullScans;
      final verifications = engine.fullVerifications;
      final w = watcher();
      FakeReadDirectoryChanges(w).rootAudit();
      expect(w.pending.toList(), [''], reason: 'the root subtree, queued');
      expect(w.fullAuditWanted, isFalse);
      var read = 0;
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (remote(path) != 'version 2') {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await engine.tick();
        read += engine.lastPass!.filesHashedBy['scan'] ?? 0;
        if (DateTime.now().isAfter(end)) fail('the audit missed the edit');
      }
      expect(read, 1, reason: 'only the edited file (of 11) is read');
      expect(engine.fullScans, scans, reason: 'not the full audit');
      expect(engine.fullVerifications, verifications);
      expect(w.overflows, 0);
    });

    test('an overflow runs the full audit and a full verification', () async {
      await silentEdit('version 3');
      final scans = engine.fullScans;
      final verifications = engine.fullVerifications;
      FakeReadDirectoryChanges(watcher()).overflow();
      await pump(() => remote(path) == 'version 3');
      expect(watcher().overflows, 1);
      expect(engine.fullScans, scans + 1);
      expect(engine.fullVerifications, verifications + 1);
      expect(engine.lastPass!.filesHashedBy['scan'], greaterThanOrEqualTo(11));
    });

    test('a failed watch handle audits the root', () async {
      await silentEdit('version 4');
      final scans = engine.fullScans;
      FakeReadDirectoryChanges(watcher()).watchFailed();
      await pump(() => remote(path) == 'version 4');
      expect(watcher().rootEvents, 1);
      expect(engine.fullScans, scans + 1);
    });

    test('a wake from sleep verifies every file', () async {
      await silentEdit('version 5');
      final verifications = engine.fullVerifications;
      FakeReadDirectoryChanges(watcher()).suspend();
      await pump(() => remote(path) == 'version 5');
      expect(watcher().suspends, 1);
      expect(engine.fullVerifications, verifications + 1);
    });
  }, skip: overInotify);

  group('Windows factory (over the Linux library)', () {
    test('only an NTFS root reports changes', () {
      const factory = WindowsChangeWatchers();
      expect(factory.watchReportsChanges(_Ntfs(), tree.fd, ''), isTrue);
      expect(
        factory.watchReportsChanges(_Ntfs(magic: 0xEF53), tree.fd, ''),
        isFalse,
      );
      expect(factory.watchReportsChanges(_NotNative(), 3, ''), isFalse);
      expect(
        () => factory.watchReportsChanges(_Ntfs(queryFails: true), tree.fd, ''),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('the adapter passes the 60-minute verification interval', () {
      final fs = windowsRootFilesystem(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
      );
      expect(fs.fullVerificationInterval, const Duration(minutes: 60));
    });

    test('the root is watched before the watcher is returned', () async {
      final started = await const WindowsChangeWatchers().changeWatcher(
        tree.native,
        tree.fd,
        tree.root.path,
        const WatcherSettings(quiet: Duration(milliseconds: 300)),
      );
      addTearDown(() => started?.close());
      expect(started, isNotNull);
      expect(started!.active, isTrue);
      expect(started.watching(''), isTrue);
      expect(started.settings.quiet, const Duration(milliseconds: 300));
    });

    test('a filesystem outside the shared binding gets no watcher', () async {
      expect(
        await const WindowsChangeWatchers().changeWatcher(
          _NotNative(),
          3,
          'root',
          const WatcherSettings(),
        ),
        isNull,
      );
    });

    test('a watch that cannot start: no watcher, and the engine keeps the '
        'stat scan', () async {
      WindowsChangeWatchers.debugFailWatch = true;
      engine.watcher!.close();
      engine.watcher = null;
      final next = SyncEngine(
        store,
        tree,
        cloud,
        watchers: const WindowsChangeWatchers(),
      );
      await next.startWatching();
      expect(next.watcher, isNull);
      expect(next.watchUnavailable, isTrue);
      expect(next.eventDriven, isFalse);
      outside.writeAsStringSync('version 6', flush: true);
      final scans = next.fullScans;
      await next.tick();
      expect(next.lastPass!.localScan, 'full');
      expect(remote(path), 'version 6');
      expect(next.fullScans, scans + 1);
    });
  });
}

class _NotNative implements RootFilesystem {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
