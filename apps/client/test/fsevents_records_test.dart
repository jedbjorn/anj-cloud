// Spec #31 M2 on the VM host: the macOS watcher's Dart side without a Mac. The
// FSEvents translation (native/posix/watch_fsevents.inc) turns stream events
// into the shared compact records; here a fake FSEvents source feeds exactly
// those records to the shared LocalWatcher (over inotify) and the engine, and
// the macOS factory's wiring and fallback run over the Linux library. The
// stream itself is proven on mac-test (native_test.sh rows and
// test_macos/fsevents_watch_macos_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/macos/macos_change_watchers.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

// The inotify mask bits the translator emits.
const inCreate = 0x100;
const inMoveSelf = 0x800;
const inIsDir = 0x40000000;

/// What watch_fsevents.inc emits for each FSEvents case (see its header).
class FakeFsEvents {
  FakeFsEvents(this.watcher);
  final LocalWatcher watcher;
  int _wd(String path) => watcher.debugWatchDescriptor(path)!;

  /// MustScanSubDirs / a drop / Mount at a non-root directory [path]: a
  /// directory creation of it on its parent (a subtree record).
  void subtree(String path) {
    final slash = path.lastIndexOf('/');
    final parent = slash < 0 ? '' : path.substring(0, slash);
    _send([_wd(parent), inCreate | inIsDir, 0, path.substring(slash + 1)]);
  }

  /// A drop at the root, or a path outside the root: IN_Q_OVERFLOW.
  void overflow() => _send([-1, inQueueOverflow, 0, '']);

  /// RootChanged: IN_MOVE_SELF on the root.
  void rootChanged() => _send([_wd(''), inMoveSelf, 0, '']);

  void _send(List<Object> records) {
    watcher.handleRecords(records);
    watcher.onChange?.call();
  }
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
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await engine.tick();
      if (watcher().queued == 0 && engine.lastPass!.pathsVisited == 0) return;
    }
    fail('did not quiesce');
  }

  /// A write through a hard link outside the root: no event in the root.
  Future<void> silentEdit(String content) async {
    outside.writeAsStringSync(content, flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.tick();
    expect(remote(path), isNot(content), reason: 'the edit sent no event');
  }

  setUp(() async {
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-fsevents-')
          .resolveSymbolicLinksSync(),
    );
    final parent = Directory('${fixture.path}/files')..createSync();
    // A trusted filesystem with periodic writeback (fake sysctls), as in
    // local_watch_test.dart, so unchanged stamps are not rehashed and a
    // silent edit stays unseen until an audit.
    final vm = Directory('${fixture.path}/vm')..createSync();
    File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('3000\n');
    File('${vm.path}/dirty_writeback_centisecs').writeAsStringSync('1500\n');
    File('${vm.path}/laptop_mode').writeAsStringSync('0\n');
    tree = RootTree.setup(parent.path, 'watch', NativeRootFs())
      ..debugFsMagic =
          0xEF53 // ext4
      ..vmDirectory = vm.path;
    store = Manifest(Directory('${fixture.path}/profile'))
      ..setSetting('retention', 'local');
    cloud = FakeCloud();
    engine = SyncEngine(store, tree, cloud)
      ..watcherSettings = const WatcherSettings(
        quiet: Duration(milliseconds: 150),
        maxDelay: Duration(seconds: 2),
      );
    await engine.startWatching();
    tree.ensureDirectory('Documents/sub');
    local(path).writeAsStringSync('version 1');
    outside = File('${fixture.path}/outside-link');
    await Process.run('ln', [local(path).path, outside.path]);
    await quiesce();
    expect(remote(path), 'version 1');
  });
  tearDown(() {
    MacosChangeWatchers.debugFailStream = false;
    engine.close();
    fixture.deleteSync(recursive: true);
  });

  group(
    'FSEvents records drive the shared watcher',
    () {
      test('MustScanSubDirs on a directory audits only that subtree', () async {
        await silentEdit('version 2');
        final scans = engine.fullScans;
        FakeFsEvents(watcher()).subtree('Documents/sub');
        await pump(() => remote(path) == 'version 2');
        expect(engine.fullScans, scans);
      });

      test('a drop at the root runs the full overflow audit', () async {
        await silentEdit('version 3');
        final scans = engine.fullScans;
        FakeFsEvents(watcher()).overflow();
        await pump(() => remote(path) == 'version 3');
        expect(watcher().overflows, 1);
        expect(engine.fullScans, scans + 1);
      });

      test('RootChanged runs the root self-audit', () async {
        await silentEdit('version 4');
        final scans = engine.fullScans;
        FakeFsEvents(watcher()).rootChanged();
        await pump(() => remote(path) == 'version 4');
        expect(watcher().rootEvents, 1);
        expect(engine.fullScans, scans + 1);
      });
    },
    skip: linuxOnly(
      'fake FSEvents records over inotify, with a hard-link edit that '
      'is silent only there; the real stream is test_macos/'
      'fsevents_watch_macos_test.dart',
    ),
  );

  group('macOS factory wiring (over the Linux library)', () {
    test('only an APFS volume key is trusted to report changes', () {
      const factory = MacosChangeWatchers();
      expect(MacosChangeWatchers.trustedVolume('u${'0' * 31}1'), isTrue);
      expect(MacosChangeWatchers.trustedVolume('16777230'), isFalse);
      // the VM host's volume keys are Linux fsids or st_dev numbers, never APFS.
      expect(factory.watchReportsChanges(tree.native, tree.fd, ''), isFalse);
    }, skip: linuxOnly('asserts that the fixture volume (The VM host) is not APFS'));

    test('the root is watched before the watcher is returned', () async {
      final started = await const MacosChangeWatchers().changeWatcher(
        tree.native,
        tree.fd,
        tree.root.path,
        const WatcherSettings(),
      );
      addTearDown(() => started?.close());
      expect(started, isNotNull);
      expect(started!.active, isTrue);
      expect(started.watching(''), isTrue);
    });

    test(
      'a stream that cannot start gives no watcher: the stat scan stays',
      () async {
        MacosChangeWatchers.debugFailStream = true;
        final started = await const MacosChangeWatchers().changeWatcher(
          tree.native,
          tree.fd,
          tree.root.path,
          const WatcherSettings(),
        );
        expect(started, isNull);
        // The engine with no watcher: every pass stat-scans the root.
        engine.watcher!.close();
        engine.watcher = null;
        outside.writeAsStringSync('version 5', flush: true);
        final scans = engine.fullScans;
        await engine.tick();
        expect(engine.lastPass!.localScan, 'full');
        expect(remote(path), 'version 5');
        expect(engine.fullScans, scans + 1);
      },
    );
  });
}
