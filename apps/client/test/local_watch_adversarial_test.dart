// Adversarial cases from the independent review of PR #23 (spec #15),
// adopted into the suite: directory churn, moves out of and back into the
// root, symlink replacement, offline and paused roots, fd/watch leaks.
// Each runs on a real disk (btrfs/ext4 under .dart_tool) and on tmpfs; on
// macOS (spec #31 M2) both are APFS, under .dart_tool and the system temp.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart'
    show macosFullVerificationInterval;
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';

/// The binding as each platform's adapter builds it: on macOS with the
/// verification interval of decision #135, so an idle pass hashes nothing
/// there too (event-driven hashing) and events alone keep the view current.
NativeRootFs platformFs() => Platform.isMacOS
    ? NativeRootFs(null, 'macOS errno', macosFullVerificationInterval)
    : NativeRootFs();

void main() {
  for (final disk in [true, false]) {
    group(disk ? 'btrfs' : 'tmpfs', () {
      late Directory base;
      late RootTree tree;
      late Manifest store;
      late FakeCloud cloud;
      late SyncEngine engine;
      var closed = false;

      setUp(() async {
        closed = false;
        base = disk
            ? (Directory(
                '.dart_tool/anj-disk-fixtures',
              )..createSync(recursive: true)).createTempSync('review23-')
            : Directory(
                Directory.systemTemp
                    .createTempSync('review23-')
                    .resolveSymbolicLinksSync(),
              );
        final parent = Directory('${base.path}/files')..createSync();
        tree = RootTree.setup(parent.path, 'disk', platformFs());
        store = Manifest(Directory('${base.path}/profile'))
          ..setSetting('retention', 'local');
        cloud = FakeCloud();
        engine = SyncEngine(store, tree, cloud)
          ..watcherSettings = const WatcherSettings(
            quiet: Duration(milliseconds: 150),
            maxDelay: Duration(seconds: 2),
          );
        await engine.startWatching();
        expect(engine.watcher, isNotNull);
        (engine.watcher! as LocalWatcher)
          ..quiet = const Duration(milliseconds: 150)
          ..maxDelay = const Duration(seconds: 2);
      });
      tearDown(() {
        if (!closed) engine.close();
        base.deleteSync(recursive: true);
      });

      String root() => tree.root.path;
      File local(String path) => File('${root()}/$path');
      String? remote(String path) {
        final bytes = cloud.files[path];
        return bytes == null ? null : utf8.decode(bytes);
      }

      Future<void> pump(
        bool Function() done, {
        Duration timeout = const Duration(seconds: 30),
      }) async {
        final end = DateTime.now().add(timeout);
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
          calm =
              (engine.watcher! as LocalWatcher).queued == 0 &&
                  (!disk || (engine.lastPass!.filesHashedBy['scan'] ?? 0) == 0)
              ? calm + 1
              : 0;
          if (calm >= 6) return;
        }
        fail('did not quiesce');
      }

      /// Directories really beneath the root (plus the root itself).
      int realDirectories() =>
          1 +
          Directory(root())
              .listSync(recursive: true, followLinks: false)
              .whereType<Directory>()
              .length;

      // macOS: listing /dev/fd fails on the listing's own descriptor
      // (EBADF), so the process's descriptors are counted with lsof.
      int openFds() => Platform.isMacOS
          ? (Process.runSync('lsof', ['-n', '-P', '-p', '$pid', '-Fd']).stdout
                    as String)
                .split('\n')
                .where((l) => RegExp(r'^f\d+$').hasMatch(l))
                .length
          : Directory('/proc/self/fd').listSync().length;

      test('mkdir -p deep and immediate writes (x20)', () async {
        await engine.tick();
        for (var i = 0; i < 20; i++) {
          final d = Directory('${root()}/Documents/n$i/a/b/c')
            ..createSync(recursive: true);
          File('${d.path}/f.txt').writeAsStringSync('deep $i');
          File('${root()}/Documents/n$i/a/top.txt').writeAsStringSync('top $i');
        }
        // Writes into the deep directory after the CREATE but very likely
        // before its watch lands (quiet 150 ms).
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (var i = 0; i < 20; i++) {
          File('${root()}/Documents/n$i/a/b/c/late.txt')
              .writeAsStringSync('late $i');
        }
        await pump(
          () => List.generate(20, (i) => i).every(
            (i) =>
                remote('Documents/n$i/a/b/c/f.txt') == 'deep $i' &&
                remote('Documents/n$i/a/b/c/late.txt') == 'late $i' &&
                remote('Documents/n$i/a/top.txt') == 'top $i',
          ),
        );
        await quiesce();
        local('Documents/n7/a/b/c/f.txt').writeAsStringSync('edited');
        await pump(() => remote('Documents/n7/a/b/c/f.txt') == 'edited');
        expect(engine.fullScans, 1, reason: 'events only');
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('mv dir out of the root, edit outside, move back', () async {
        Directory('${root()}/Documents/m/sub').createSync(recursive: true);
        local('Documents/m/sub/x.txt').writeAsStringSync('x');
        await quiesce();
        final outside = Directory('${base.path}/outside')..createSync();
        Directory('${root()}/Documents/m').renameSync('${outside.path}/m');
        await quiesce();
        // Edits outside must not be attributed to the root.
        File('${outside.path}/m/sub/out.txt').writeAsStringSync('out');
        File('${outside.path}/m/sub/x.txt').writeAsStringSync('x-out');
        await quiesce();
        expect(remote('Documents/m/sub/out.txt'), isNull);
        expect(
          (engine.watcher! as LocalWatcher).watches,
          realDirectories(),
          reason: 'no watch left on the moved-out tree',
        );
        Directory('${outside.path}/m').renameSync('${root()}/Documents/m2');
        await pump(() => remote('Documents/m2/sub/out.txt') == 'out');
        expect(remote('Documents/m2/sub/x.txt'), 'x-out');
        await quiesce();
        local('Documents/m2/sub/x.txt').writeAsStringSync('x2');
        await pump(() => remote('Documents/m2/sub/x.txt') == 'x2');
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
        expect(engine.fullScans, 1);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('mv out and back within the quiet period', () async {
        Directory('${root()}/Documents/q/sub').createSync(recursive: true);
        local('Documents/q/sub/x.txt').writeAsStringSync('x');
        await quiesce();
        final outside = Directory('${base.path}/outside')..createSync();
        Directory('${root()}/Documents/q').renameSync('${outside.path}/q');
        File('${outside.path}/q/sub/y.txt').writeAsStringSync('y');
        Directory('${outside.path}/q').renameSync('${root()}/Documents/q');
        await pump(() => remote('Documents/q/sub/y.txt') == 'y');
        await quiesce();
        local('Documents/q/sub/x.txt').writeAsStringSync('x2');
        await pump(() => remote('Documents/q/sub/x.txt') == 'x2');
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('cross-directory directory move then edit at new path', () async {
        Directory('${root()}/Documents/a/inner').createSync(recursive: true);
        Directory('${root()}/Music').createSync(recursive: true);
        local('Documents/a/inner/z.txt').writeAsStringSync('z');
        await quiesce();
        Directory('${root()}/Documents/a').renameSync('${root()}/Music/a');
        // Immediate write before rescans.
        local('Music/a/inner/now.txt').writeAsStringSync('now');
        await pump(() => remote('Music/a/inner/now.txt') == 'now');
        await quiesce();
        local('Music/a/inner/z.txt').writeAsStringSync('z2');
        await pump(() => remote('Music/a/inner/z.txt') == 'z2');
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
        expect(engine.fullScans, 1);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('watched dir replaced by a symlink to outside the root', () async {
        Directory('${root()}/Documents/s/sub').createSync(recursive: true);
        local('Documents/s/sub/a.txt').writeAsStringSync('a');
        await quiesce();
        final outside = Directory('${base.path}/outside')..createSync();
        Directory('${root()}/Documents/s').renameSync('${outside.path}/s');
        Link('${root()}/Documents/s').createSync('${outside.path}/s');
        await quiesce();
        File('${outside.path}/s/sub/new.txt').writeAsStringSync('secret');
        File('${outside.path}/s/sub/a.txt').writeAsStringSync('changed');
        Directory('${outside.path}/s/sub/deeper').createSync();
        File('${outside.path}/s/sub/deeper/d.txt').writeAsStringSync('d');
        await quiesce();
        for (final v in cloud.files.values) {
          final text = utf8.decode(v);
          expect(text, isNot(anyOf('secret', 'changed', 'd')));
        }
        expect(
          (engine.watcher! as LocalWatcher).watches,
          realDirectories(),
          reason: 'no watch follows the symlink',
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('directory deleted and recreated, immediate write', () async {
        Directory('${root()}/Documents/r').createSync(recursive: true);
        local('Documents/r/old.txt').writeAsStringSync('old');
        await quiesce();
        Directory('${root()}/Documents/r').deleteSync(recursive: true);
        Directory('${root()}/Documents/r').createSync();
        local('Documents/r/n.txt').writeAsStringSync('n');
        await pump(() => remote('Documents/r/n.txt') == 'n');
        await quiesce();
        local('Documents/r/n.txt').writeAsStringSync('n2');
        await pump(() => remote('Documents/r/n.txt') == 'n2');
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('edit while offline and while the root is moved away', () async {
        local('Documents/o.txt').writeAsStringSync('o1');
        await quiesce();
        cloud.online = false;
        local('Documents/o.txt').writeAsStringSync('o2');
        Directory('${root()}/Documents/off/a/b').createSync(recursive: true);
        local('Documents/off/a/b/f.txt').writeAsStringSync('f');
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await engine.tick();
        }
        cloud.online = true;
        await pump(
          () =>
              remote('Documents/o.txt') == 'o2' &&
              remote('Documents/off/a/b/f.txt') == 'f',
        );
        await quiesce();
        final away = '${base.path}/files/away';
        tree.root.renameSync(away);
        await pump(() => engine.message.startsWith('Paused'));
        File('$away/Documents/o.txt').writeAsStringSync('o3');
        Directory('$away/Documents/off2').createSync();
        File('$away/Documents/off2/g.txt').writeAsStringSync('g');
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await engine.tick();
        }
        Directory(away).renameSync(root());
        await pump(
          () =>
              remote('Documents/o.txt') == 'o3' &&
              remote('Documents/off2/g.txt') == 'g',
        );
        await quiesce();
        local('Documents/off2/g.txt').writeAsStringSync('g2');
        await pump(() => remote('Documents/off2/g.txt') == 'g2');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('no fd or watch leak over directory churn', () async {
        await quiesce();
        final fds = openFds();
        for (var round = 0; round < 30; round++) {
          final d = Directory('${root()}/Documents/churn$round/x/y')
            ..createSync(recursive: true);
          File('${d.path}/f').writeAsStringSync('$round');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (round.isOdd) {
            Directory('${root()}/Documents/churn$round')
                .deleteSync(recursive: true);
          } else {
            Directory('${root()}/Documents/churn$round')
                .renameSync('${root()}/Documents/moved$round');
          }
        }
        await quiesce();
        await quiesce();
        expect((engine.watcher! as LocalWatcher).watches, realDirectories());
        expect(openFds(), fds);
        engine.close();
        closed = true;
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  }
}
