@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// Spec #32 "File Watching" (Acceptance row 9) on W10C-Testing: the
/// ReadDirectoryChangesW watcher in anj_rootfs.dll behind the shared
/// LocalWatcher and the engine, unelevated (tool/windows/native_test.ps1
/// -Dart). The overflow and handle-failure cases need the test build's
/// anj_win_watch_* seams (the DLL native_test.ps1 builds with
/// -DANJ_TEST_SEAMS); they are skipped against a shipped DLL.
void main() {
  late Directory temp;
  late NativeRootFs fs;
  late RootTree tree;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('anj-ww-dart-');
    fs = platformAdapters().rootFilesystem() as NativeRootFs;
    tree = RootTree.setup(temp.path, 'ww', fs);
  });
  tearDown(() {
    tree.close();
    temp.deleteSync(recursive: true);
  });

  File inRoot(String relative) => File(p.join(tree.root.path, relative));

  /// The test build's tiny-buffer seam (64 bytes), or null.
  void Function(Pointer<Void>)? seam(String name) {
    try {
      final f = fs.lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32),
            int Function(Pointer<Void>, int)
          >(name);
      return (handle) => f(handle, 64);
    } on ArgumentError {
      return null;
    }
  }

  void Function(Pointer<Void>)? cancelSeam() {
    try {
      final f = fs.lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('anj_win_watch_debug_cancel');
      return (handle) => f(handle);
    } on ArgumentError {
      return null;
    }
  }

  test('the platform factory is the Windows one and the root reports '
      'changes', () {
    expect(platformWatchers(), isA<WindowsChangeWatchers>());
    expect(platformAdapters().watchReportsChanges(fs, tree.fd, ''), isTrue);
    expect(fs.fullVerificationInterval, const Duration(minutes: 60));
  });

  test('a 5,000-file burst is covered within quiet + maxDelay', () async {
    const settings = WatcherSettings();
    final started = await const WindowsChangeWatchers().changeWatcher(
      fs,
      tree.fd,
      tree.root.path,
      settings,
    );
    expect(started, isNotNull);
    final watcher = started! as LocalWatcher;
    addTearDown(watcher.close);
    // ignore: avoid_print
    print('WW stage: watching');
    Directory(p.join(tree.root.path, 'Documents', 'burst')).createSync();
    await Future<void>.delayed(const Duration(seconds: 3));
    watcher.take();
    watcher.beginFullAudit();
    final began = DateTime.now();
    for (var i = 0; i < 5000; i++) {
      inRoot('Documents/burst/f$i.txt').writeAsStringSync('x');
    }
    final written = DateTime.now();
    // ignore: avoid_print
    print('WW stage: written');
    final covered = <String>{};
    var full = false;
    final subtrees = <String>{};
    // Every name, or the folder's own subtree audit; an overflow (the full
    // audit) ends the wait and fails the test.
    bool done() =>
        full ||
        covered.length == 5000 ||
        subtrees.any((s) => s == '' || 'Documents/burst'.startsWith(s));
    final limit = settings.quiet + settings.maxDelay;
    while (!done() && DateTime.now().difference(written) < limit * 2) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (watcher.fullAuditWanted) full = true;
      final work = watcher.take();
      full |= work.full;
      subtrees.addAll(work.subtrees);
      for (final path in work.paths) {
        if (path.startsWith('Documents/burst/f')) covered.add(path);
      }
    }
    final after = DateTime.now().difference(written);
    // ignore: avoid_print
    print(
      'WW burst: 5000 files written in ${written.difference(began).inMilliseconds} ms; '
      'covered ${after.inMilliseconds} ms after the last write '
      '(paths ${covered.length}, subtrees $subtrees, full $full, '
      'overflows ${watcher.overflows}, collapses ${watcher.collapses}); '
      'limit ${limit.inMilliseconds} ms',
    );
    expect(full, isFalse, reason: 'no overflow audit');
    expect(watcher.overflows, 0);
    expect(done(), isTrue);
    expect(after, lessThanOrEqualTo(limit));
  });

  test('a forced overflow (tiny buffer) asks for the full audit, and the '
      'engine runs it', () async {
    final tiny = seam('anj_win_watch_debug_buffer');
    if (tiny == null) {
      markTestSkipped('shipped DLL: no anj_win_watch_debug_buffer');
      return;
    }
    final watcher = await LocalWatcher.start(fs, tree.fd, tree.root.path);
    expect(watcher, isNotNull);
    tiny(watcher!.handle);
    watcher.add('');
    expect(watcher.watching(''), isTrue);
    final store = Manifest(Directory(p.join(temp.path, 'profile')))
      ..setSetting('retention', 'local');
    final engine = SyncEngine(store, tree, FakeCloud());
    addTearDown(engine.close);
    engine.attachWatcher(watcher);
    await engine.tick();
    final scans = engine.fullScans;
    // A few files: fewer overflows than fail the watch (32 within a second).
    for (var i = 0; i < 5; i++) {
      inRoot('Music/g$i.txt').writeAsStringSync('y');
    }
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (watcher.overflows == 0 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(watcher.overflows, greaterThan(0));
    expect(watcher.failure, isNull, reason: 'a few overflows keep the watch');
    await engine.tick();
    expect(engine.fullScans, scans + 1, reason: 'the overflow audit');
    expect(engine.lastPass!.localScan, 'full');
  });

  test('a failed watch handle audits the root, the engine stat-scans, then '
      'restarts the watcher with the same settings', () async {
    final cancel = cancelSeam();
    if (cancel == null) {
      markTestSkipped('shipped DLL: no anj_win_watch_debug_cancel');
      return;
    }
    final store = Manifest(Directory(p.join(temp.path, 'profile')))
      ..setSetting('retention', 'local');
    final engine = SyncEngine(store, tree, FakeCloud())
      ..watcherSettings = const WatcherSettings(
        quiet: Duration(milliseconds: 400),
      )
      ..watchRestartDelay = const Duration(seconds: 1);
    addTearDown(engine.close);
    await engine.startWatching();
    final first = engine.watcher! as LocalWatcher;
    await engine.tick();
    cancel(first.handle);
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (first.failure == null && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(first.rootEvents, greaterThan(0), reason: 'the root audit record');
    expect(first.failure, isNotNull);
    final scans = engine.fullScans;
    await engine.tick();
    expect(engine.fullScans, greaterThan(scans), reason: 'stat scan meanwhile');
    final restartBy = DateTime.now().add(const Duration(seconds: 15));
    while (identical(engine.watcher, first) &&
        DateTime.now().isBefore(restartBy)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.tick();
    }
    expect(engine.watcher, isNot(same(first)));
    expect(engine.watcher!.active, isTrue);
    expect(engine.watcher!.settings.quiet, const Duration(milliseconds: 400));
  });
}
