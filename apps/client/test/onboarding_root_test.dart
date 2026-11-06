// Spec #34 P1-P3 (Linux first): the automatic root, the desktop shortcut and
// staging out of sight. Every home, desktop and profile here is a temporary
// directory; no test reads or writes the real home folder.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/local/staging_location.dart';
import 'package:anj_cloud/core/ports/root_placement.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/platform/linux/xdg_root_placement.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/ui/app.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  if (skipSuite('Onboarding root (Linux)', linuxOnly('XDG home layout'))) {
    return;
  }
  late Directory fixture;
  late Directory home;
  late Directory profile;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-onboarding-');
    home = Directory(p.join(fixture.path, 'home'))..createSync();
    profile = Directory(p.join(fixture.path, 'state', 'profile'));
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  XdgRootPlacement placement([Map<String, String> extra = const {}]) =>
      XdgRootPlacement(environment: {'HOME': home.path, ...extra});

  ClientController client({XdgRootPlacement? where}) => ClientController(
    profile,
    secrets: MemorySecrets(),
    nativeLibrary: testNativeLibrary,
    placement: where ?? placement(),
  );

  String? setting(String key) {
    final store = Manifest(profile);
    try {
      return store.setting(key);
    } finally {
      store.close();
    }
  }

  group('P1 automatic root', () {
    test('a new profile creates \$HOME/anj-cloud without a picker', () async {
      final controller = client();
      try {
        await controller.initialize();
        final root = p.join(home.resolveSymbolicLinksSync(), 'anj-cloud');
        expect(controller.root, root);
        expect(controller.rootProblem, isNull);
        expect(controller.settingUpRoot, isFalse);
        for (final name in ['Music', 'Videos', 'Documents']) {
          expect(Directory(p.join(root, name)).existsSync(), isTrue);
        }
        expect(setting('root'), root);
        expect(setting('rootCreating'), isNull);
        // P3: same filesystem, so staging is inside the profile; nothing
        // but anj-cloud/ was added to the home folder.
        expect(
          setting('staging'),
          p.join(profile.resolveSymbolicLinksSync(), 'staging'),
        );
        expect(home.listSync().map((e) => p.basename(e.path)), ['anj-cloud']);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('an existing anj-cloud folder is refused with the reason, never '
        'adopted; Use another folder still works', () async {
      final existing = Directory(p.join(home.path, 'anj-cloud'))..createSync();
      File(p.join(existing.path, 'other-tool.txt')).writeAsStringSync('x');
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, isNull);
        expect(controller.rootProblem, contains('already exists'));
        expect(controller.rootProblem, contains(existing.path));
        expect(existing.listSync().map((e) => p.basename(e.path)), [
          'other-tool.txt',
        ]);
        expect(setting('root'), isNull);
        expect(setting('rootCreating'), isNull);
        final other = Directory(p.join(fixture.path, 'elsewhere'))
          ..createSync();
        await controller.configureRoot(other.path);
        expect(controller.root, p.join(other.path, 'anj-cloud'));
        expect(controller.rootProblem, isNull);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('an overlap refusal shows the reason and creates nothing', () async {
      // The profile itself lives where the synced folder would go.
      profile = Directory(p.join(home.path, 'anj-cloud', 'profile'));
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, isNull);
        expect(controller.rootProblem, contains('does not overlap'));
        expect(
          Directory(p.join(home.path, 'anj-cloud', 'Documents')).existsSync(),
          isFalse,
        );
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('a creation interrupted before the root was recorded is finished '
        'at the next start', () async {
      final target = p.join(home.resolveSymbolicLinksSync(), 'anj-cloud');
      profile.createSync(recursive: true);
      final store = Manifest(profile);
      store.setSetting('profileId', 'interrupted-profile-id');
      store.setSetting('rootCreating', target);
      store.close();
      Directory(target).createSync();
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, target);
        expect(setting('rootCreating'), isNull);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    testWidgets('a refusal shows the reason and offers Use another folder', (
      tester,
    ) async {
      final controller = ClientController(
        Directory('/unused-onboarding-profile'),
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: XdgRootPlacement(environment: {'HOME': '/home/someone'}),
      );
      controller.rootProblem =
          '/home/someone/anj-cloud already exists, so it was not used.';
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(find.text('Choose root'), findsNothing);
      await tester.tap(find.text('Use another folder'));
      await tester.pumpAndSettle();
      expect(find.text('Parent directory'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // While the automatic root is being created no picker is offered.
      controller.settingUpRoot = true;
      controller.rootProblem = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.text('Use another folder'), findsNothing);
      expect(find.text('Creating your anj-cloud folder…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  group('P2 desktop shortcut', () {
    test('created once in the XDG desktop directory; a deleted link is not '
        'recreated', () async {
      Directory(p.join(home.path, '.config')).createSync();
      File(p.join(home.path, '.config', 'user-dirs.dirs'))
          .writeAsStringSync('# xdg\nXDG_DESKTOP_DIR="\$HOME/Bureau"\n');
      final desktop = Directory(p.join(home.path, 'Bureau'))..createSync();
      final link = Link(p.join(desktop.path, 'AnJ Cloud'));
      var controller = client();
      try {
        await controller.initialize();
        expect(link.targetSync(), controller.root);
        expect(setting('desktopShortcut'), 'created:${link.path}');
      } finally {
        await controller.stop();
        controller.dispose();
      }
      link.deleteSync();
      controller = client();
      try {
        await controller.initialize();
        expect(controller.root, isNotNull);
        expect(link.existsSync(), isFalse);
        expect(FileSystemEntity.isLinkSync(link.path), isFalse);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('an existing entry with that name is left alone', () async {
      final desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
      final foreign = File(p.join(desktop.path, 'AnJ Cloud'))
        ..writeAsStringSync('mine');
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, isNotNull);
        expect(foreign.readAsStringSync(), 'mine');
        expect(setting('desktopShortcut'), 'foreign:${foreign.path}');
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('no desktop directory: no shortcut, and the home folder is never '
        'used as one', () async {
      final controller = client(
        where: placement({'XDG_DESKTOP_DIR': home.path}),
      );
      try {
        await controller.initialize();
        expect(controller.root, isNotNull);
        expect(setting('desktopShortcut'), 'none');
        expect(home.listSync().map((e) => p.basename(e.path)), ['anj-cloud']);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('the picker root gets the shortcut too', () async {
      final desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
      final controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: placement(),
      );
      // The automatic root was refused (an existing folder) first.
      Directory(p.join(home.path, 'anj-cloud')).createSync();
      try {
        await controller.initialize();
        expect(Link(p.join(desktop.path, 'AnJ Cloud')).existsSync(), isFalse);
        final other = Directory(p.join(fixture.path, 'other'))..createSync();
        await controller.configureRoot(other.path);
        expect(
          Link(p.join(desktop.path, 'AnJ Cloud')).targetSync(),
          p.join(other.path, 'anj-cloud'),
        );
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('desktop resolution follows xdg-user-dir', () {
      final desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
      expect(placement().desktopDirectory(), desktop.path);
      final other = Directory(p.join(fixture.path, 'xdg-desktop'))
        ..createSync();
      expect(
        placement({'XDG_DESKTOP_DIR': other.path}).desktopDirectory(),
        other.path,
      );
      final config = Directory(p.join(fixture.path, 'config'))..createSync();
      File(p.join(config.path, 'user-dirs.dirs'))
          .writeAsStringSync('XDG_DESKTOP_DIR="\$HOME/"\n');
      // A disabled desktop (the home folder itself) means none.
      expect(
        placement({
          'XDG_CONFIG_HOME': config.path,
          'XDG_DESKTOP_DIR': other.path,
        }).desktopDirectory(),
        isNull,
      );
      desktop.deleteSync();
      expect(placement().desktopDirectory(), isNull);
    });
  });

  group('P3 staging', () {
    final native = NativeRootFs(testNativeLibrary);

    test('another filesystem: a dot-named sibling of the root', () {
      final shm = Directory('/dev/shm');
      if (!shm.existsSync()) {
        markTestSkipped('needs /dev/shm (a second tmpfs)');
        return;
      }
      final other = shm.createTempSync('anj-onboarding-profile-');
      try {
        final tree = RootTree.setup(
          home.path,
          '0123456789abcdef0123456789abcdef',
          native,
          profileDir: other.path,
        );
        try {
          String volume(String path) {
            final fd = native.openRoot(path);
            try {
              return native.identity(fd).split(':').first;
            } finally {
              native.closeFd(fd);
            }
          }

          if (volume(other.path) == volume(home.path)) {
            markTestSkipped('/dev/shm and the temp dir share a volume here');
            return;
          }
          expect(
            tree.staging.path,
            p.join(
              home.resolveSymbolicLinksSync(),
              '.anj-cloud-staging-01234567',
            ),
          );
          expect(
            Directory(p.join(other.path, 'staging')).existsSync(),
            isFalse,
          );
        } finally {
          tree.close();
        }
      } finally {
        other.deleteSync(recursive: true);
      }
    });

    test('another btrfs subvolume: a dot-named sibling of the root', () {
      // A subvolume is created beside the build output (never in a home or
      // profile in use) and removed with rmdir once empty.
      final base = Directory('.dart_tool').createTempSync('anj-subvolume-');
      final sub = p.join(base.path, 'sub');
      try {
        final made = Process.runSync('btrfs', ['subvolume', 'create', sub]);
        if (made.exitCode != 0) {
          markTestSkipped('needs btrfs here (unprivileged subvolume create)');
          return;
        }
        final profileDir = Directory(p.join(sub, 'profile'))..createSync();
        final parent = Directory(p.join(base.path, 'parent'))..createSync();
        final tree = RootTree.setup(
          parent.path,
          'fedcba9876543210fedcba9876543210',
          native,
          profileDir: profileDir.path,
        );
        tree.close();
        expect(
          tree.staging.path,
          p.join(
            parent.resolveSymbolicLinksSync(),
            '.anj-cloud-staging-fedcba98',
          ),
        );
        expect(
          Directory(p.join(profileDir.path, 'staging')).existsSync(),
          isFalse,
        );
        // Same subvolume: inside the profile.
        final near = Directory(p.join(sub, 'near'))..createSync();
        final inside = RootTree.setup(
          near.path,
          'fedcba9876543210fedcba9876543210',
          native,
          profileDir: profileDir.path,
        );
        inside.close();
        expect(inside.staging.path, p.join(profileDir.path, 'staging'));
      } finally {
        if (Directory(sub).existsSync()) {
          for (final entry in Directory(sub).listSync()) {
            entry.deleteSync(recursive: true);
          }
          Directory(sub).deleteSync();
        }
        base.deleteSync(recursive: true);
      }
    });

    /// A pre-P3 profile: root `<parent>/anj-cloud`, staging the sibling
    /// `.anj-cloud-<profileId>`.
    Manifest legacyProfile(String id) {
      final parent = Directory(p.join(fixture.path, 'legacy'))..createSync();
      final tree = RootTree.setup(parent.path, id, native);
      final identity = native.rootInfo(tree.fd).identity;
      tree.close();
      profile.createSync(recursive: true);
      final store = Manifest(profile);
      store.setSetting('profileId', id);
      store.setSetting('root', tree.root.path);
      store.setSetting('staging', tree.staging.path);
      store.setSetting('rootIdentity', identity);
      return store;
    }

    test('an empty sibling moves into the profile and is removed', () {
      final store = legacyProfile('aaaaaaaabbbbbbbbccccccccdddddddd');
      try {
        final old = store.setting('staging')!;
        final settled = settleStaging(store, profile.path, native);
        expect(settled, p.join(profile.path, 'staging'));
        expect(store.setting('staging'), settled);
        expect(store.setting('stagingMovedFrom'), isNull);
        expect(Directory(old).existsSync(), isFalse);
        expect(Directory(settled).existsSync(), isTrue);
        // Settled: a second start changes nothing.
        expect(settleStaging(store, profile.path, native), settled);
      } finally {
        store.close();
      }
    });

    test('a sibling with files or journaled work is kept and retried', () {
      final store = legacyProfile('11111111222222223333333344444444');
      try {
        final old = store.setting('staging')!;
        final file = File(p.join(old, 'download-x'))..writeAsStringSync('d');
        expect(settleStaging(store, profile.path, native), old);
        expect(file.readAsStringSync(), 'd');
        file.deleteSync();
        // Empty, but an operation still names a file there.
        store.operations['op'] = Operation(
          'op',
          'artifact',
          'Documents/a.txt',
          staged: p.join(old, 'download-y'),
        );
        store.save();
        expect(settleStaging(store, profile.path, native), old);
        expect(Directory(old).existsSync(), isTrue);
        store.operations.remove('op');
        store.save();
        expect(
          settleStaging(store, profile.path, native),
          p.join(profile.path, 'staging'),
        );
        expect(Directory(old).existsSync(), isFalse);
      } finally {
        store.close();
      }
    });

    test(
      'review L3: a recovery copy an entry still names keeps the sibling',
      () {
        final store = legacyProfile('abababababababababababababababab');
        try {
          final old = store.setting('staging')!;
          for (final set in <void Function(Entry)>[
            (e) => e.preservedCopies = [p.join(old, 'preserved-gone')],
            (e) => e.remoteCopy = p.join(old, 'conflict-gone'),
          ]) {
            store.entries['Documents/a.txt'] = Entry(
              'Documents/a.txt',
              ItemKind.file,
            );
            set(store.entries['Documents/a.txt']!);
            store.save();
            expect(settleStaging(store, profile.path, native), old);
            expect(Directory(old).existsSync(), isTrue);
            store.entries.remove('Documents/a.txt');
            store.save();
          }
          expect(
            settleStaging(store, profile.path, native),
            p.join(profile.path, 'staging'),
          );
        } finally {
          store.close();
        }
      },
    );

    test(
      'review L2: no definite answer (a read-only root) keeps the sibling',
      () {
        final store = legacyProfile('cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd');
        final root = Directory(store.setting('root')!);
        try {
          final old = store.setting('staging')!;
          root.statSync();
          Process.runSync('chmod', ['0555', root.path]);
          expect(settleStaging(store, profile.path, native), old);
          expect(store.setting('staging'), old);
          expect(Directory(old).existsSync(), isTrue);
          expect(
            Directory(p.join(profile.path, 'staging')).existsSync(),
            isFalse,
          );
          Process.runSync('chmod', ['0755', root.path]);
          expect(
            settleStaging(store, profile.path, native),
            p.join(profile.path, 'staging'),
          );
        } finally {
          Process.runSync('chmod', ['0755', root.path]);
          store.close();
        }
      },
    );

    test('review L4: a root whose identity is not the recorded one decides '
        'nothing', () {
      final store = legacyProfile('efefefefefefefefefefefefefefefef');
      try {
        final old = store.setting('staging')!;
        store.setSetting('rootIdentity', 'f1234:99999');
        expect(settleStaging(store, profile.path, native), old);
        expect(Directory(old).existsSync(), isTrue);
      } finally {
        store.close();
      }
    });

    test('review L1: a stale probe left in the root is removed and never '
        'synced', () {
      final store = legacyProfile('12121212121212121212121212121212');
      try {
        final name = '.anj-cloud-probe-${'a' * 32}';
        final stale = Directory(p.join(store.setting('root')!, name))
          ..createSync();
        expect(isSyncExcluded(name), isTrue);
        settleStaging(store, profile.path, native);
        expect(stale.existsSync(), isFalse);
        // New roots sweep it too.
        final parent = Directory(p.join(fixture.path, 'fresh'))..createSync();
        final again = Directory(p.join(parent.path, 'anj-cloud', name))
          ..createSync(recursive: true);
        RootTree.setup(
          parent.path,
          '34343434343434343434343434343434',
          native,
          profileDir: profile.path,
        ).close();
        expect(again.existsSync(), isFalse);
      } finally {
        store.close();
      }
    });

    test('an interrupted move finishes removing the empty sibling', () {
      final store = legacyProfile('99999999888888887777777766666666');
      try {
        final old = store.setting('staging')!;
        store.setSetting('staging', p.join(profile.path, 'staging'));
        store.setSetting('stagingMovedFrom', old);
        expect(
          settleStaging(store, profile.path, native),
          p.join(profile.path, 'staging'),
        );
        expect(Directory(old).existsSync(), isFalse);
        expect(store.setting('stagingMovedFrom'), isNull);
      } finally {
        store.close();
      }
    });

    test('delta M-a: without P3 (macOS, Windows: the picker-only placement) '
        'staging stays the sibling and an existing one is not moved', () async {
      final store = legacyProfile('7777777766666666555555554444444a');
      final old = store.setting('staging')!;
      store.close();
      var controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: const PickerOnlyPlacement(),
      );
      try {
        await controller.initialize();
        expect(setting('staging'), old);
        expect(Directory(old).existsSync(), isTrue);
        expect(
          Directory(p.join(profile.path, 'staging')).existsSync(),
          isFalse,
        );
      } finally {
        await controller.stop();
        controller.dispose();
      }
      // A new root without P3 stages in the earlier sibling.
      profile = Directory(p.join(fixture.path, 'state', 'other-profile'));
      final parent = Directory(p.join(fixture.path, 'picked'))..createSync();
      controller = ClientController(
        profile,
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
        placement: const PickerOnlyPlacement(),
      );
      try {
        await controller.initialize();
        await controller.configureRoot(parent.path);
        expect(
          setting('staging'),
          p.join(parent.path, '.anj-cloud-${setting('profileId')}'),
        );
        expect(
          Directory(p.join(profile.path, 'staging')).existsSync(),
          isFalse,
        );
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('a worker start moves an existing profile\'s empty sibling', () async {
      final store = legacyProfile('5555555566666666777777778888888a');
      final old = store.setting('staging')!;
      store.close();
      final controller = client();
      try {
        await controller.initialize();
        expect(setting('staging'), p.join(profile.path, 'staging'));
        expect(Directory(old).existsSync(), isFalse);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });
  });
}
