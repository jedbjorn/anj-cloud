// Spec #31 M8 (decision #164): onboarding parity on macOS, spec #34 P1-P3
// through MacosRootPlacement and the shared controller logic. Runs on the VM host
// (the shared logic over the Linux library) and on mac-test (APFS, the
// Darwin dylib). Every home, desktop and profile is a temporary directory;
// no test reads or writes the real home folder or Desktop.
import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/ports/root_placement.dart';
import 'package:anj_cloud/platform/macos/macos_root_placement.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  late Directory fixture;
  late Directory home;
  late Directory profile;
  setUp(() {
    // Resolved: the root opens refuse a symlink in the path, and macOS's
    // temporary directories sit under /private.
    fixture = Directory(
      Directory.systemTemp
          .createTempSync('anj-macos-onboarding-')
          .resolveSymbolicLinksSync(),
    );
    home = Directory(p.join(fixture.path, 'home'))..createSync();
    profile = Directory(
      p.join(fixture.path, 'Library', 'Application Support', 'profile'),
    );
  });
  tearDown(() => fixture.deleteSync(recursive: true));

  MacosRootPlacement placement() =>
      MacosRootPlacement(environment: {'HOME': home.path});

  ClientController client() => ClientController(
    profile,
    secrets: MemorySecrets(),
    nativeLibrary: testNativeLibrary,
    placement: placement(),
  );

  String? setting(String key) {
    final store = Manifest(profile);
    try {
      return store.setting(key);
    } finally {
      store.close();
    }
  }

  group('MacosRootPlacement', () {
    test('the home folder is the parent; a reserved root wins', () {
      expect(placement().defaultParent(), home.path);
      expect(
        MacosRootPlacement(
          environment: {'HOME': home.path},
          reservedParent: '/Volumes/Data/someone',
        ).defaultParent(),
        '/Volumes/Data/someone',
      );
      expect(MacosRootPlacement(environment: const {}).defaultParent(), isNull);
      expect(
        MacosRootPlacement(environment: const {'HOME': 'relative'})
            .defaultParent(),
        isNull,
      );
    });

    test('~/Desktop only when it is a folder', () {
      expect(placement().desktopDirectory(), isNull);
      File(p.join(home.path, 'Desktop')).writeAsStringSync('not a folder');
      expect(placement().desktopDirectory(), isNull);
      File(p.join(home.path, 'Desktop')).deleteSync();
      Directory(p.join(home.path, 'Desktop')).createSync();
      expect(placement().desktopDirectory(), p.join(home.path, 'Desktop'));
    });

    test('staging goes inside the profile (proved by the shared probe)', () {
      expect(placement().stagingInProfile, isTrue);
    });
  });

  group('P1-P3 through the shared controller', () {
    test('a new profile creates ~/anj-cloud with no picker, the Desktop '
        'link once and staging inside the profile', () async {
      final desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
      final controller = client();
      try {
        await controller.initialize();
        final root = p.join(home.path, 'anj-cloud');
        expect(controller.root, root, reason: controller.message);
        expect(controller.rootProblem, isNull);
        expect(controller.automaticRoot, isTrue);
        for (final name in ['Music', 'Videos', 'Documents']) {
          expect(
            Directory(p.join(root, name)).existsSync(),
            isTrue,
            reason: name,
          );
        }
        final link = Link(p.join(desktop.path, 'AnJ Cloud'));
        expect(link.targetSync(), root);
        expect(setting('desktopShortcut'), 'created:${link.path}');
        expect(
          setting('staging'),
          p.join(profile.resolveSymbolicLinksSync(), 'staging'),
        );
        // Nothing but anj-cloud/ and the Desktop was added to the home.
        expect(home.listSync().map((e) => p.basename(e.path)).toSet(), {
          'anj-cloud',
          'Desktop',
        });
      } finally {
        await controller.stop();
        controller.dispose();
      }
      // A deleted link is not made again at the next start.
      Link(p.join(desktop.path, 'AnJ Cloud')).deleteSync();
      final again = client();
      try {
        await again.initialize();
        expect(
          FileSystemEntity.typeSync(
            p.join(desktop.path, 'AnJ Cloud'),
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
      } finally {
        await again.stop();
        again.dispose();
      }
    });

    test(
      'a Desktop that refuses the link (privacy refusal) is recorded '
      'once; sync is unaffected',
      () async {
        final desktop = Directory(p.join(home.path, 'Desktop'))..createSync();
        // A folder the app cannot write stands in for a refused Desktop.
        Process.runSync('chmod', ['0500', desktop.path]);
        final controller = client();
        try {
          await controller.initialize();
          expect(controller.root, p.join(home.path, 'anj-cloud'));
          expect(controller.rootProblem, isNull);
          expect(setting('desktopShortcut'), 'failed');
        } finally {
          await controller.stop();
          controller.dispose();
          Process.runSync('chmod', ['0700', desktop.path]);
        }
      },
      skip:
          Platform.isLinux &&
              Process.runSync('id', ['-u']).stdout.toString().trim() == '0'
          ? 'root ignores folder permissions'
          : false,
    );

    test(
      'a manifest held by another writer when the outcome is saved '
      'leaves it unrecorded; root setup still succeeds (PR #100 L1)',
      () async {
        Directory(p.join(home.path, 'Desktop')).createSync();
        // Another writer holds the manifest while the link is being made (as
        // a worker another path started would, while a macOS Desktop prompt
        // is pending): the outcome's save then meets "database is locked".
        final held = _HoldingPlacement(placement(), profile);
        final controller = ClientController(
          profile,
          secrets: MemorySecrets(),
          nativeLibrary: testNativeLibrary,
          placement: held,
        );
        try {
          await controller.initialize();
          expect(held.held, isTrue, reason: 'the lock was taken');
          final root = p.join(home.path, 'anj-cloud');
          expect(controller.root, root);
          expect(controller.rootProblem, isNull);
          expect(
            Link(p.join(home.path, 'Desktop', 'AnJ Cloud')).targetSync(),
            root,
          );
          held.release();
          expect(setting('root'), root);
          expect(setting('desktopShortcut'), isNull, reason: 'not recorded');
        } finally {
          held.release();
          await controller.stop();
          controller.dispose();
        }
      },
    );

    test('no Desktop folder: no link, recorded as none', () async {
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, p.join(home.path, 'anj-cloud'));
        expect(setting('desktopShortcut'), 'none');
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });

    test('an existing ~/anj-cloud is refused with its reason and the picker '
        'offered', () async {
      Directory(p.join(home.path, 'anj-cloud')).createSync();
      final controller = client();
      try {
        await controller.initialize();
        expect(controller.root, isNull);
        expect(controller.rootProblem, isNotNull);
        expect(controller.automaticRoot, isTrue);
      } finally {
        await controller.stop();
        controller.dispose();
      }
    });
  });
}

/// [MacosRootPlacement] that takes an exclusive write lock on the profile's
/// manifest when the controller asks for the desktop directory, until
/// [release].
class _HoldingPlacement implements RootPlacement {
  _HoldingPlacement(this.inner, this.profile);
  final MacosRootPlacement inner;
  final Directory profile;
  Database? _db;
  bool held = false;

  @override
  String? defaultParent() => inner.defaultParent();

  @override
  bool get stagingInProfile => inner.stagingInProfile;

  @override
  Set<String> keptDirectories() => inner.keptDirectories();

  @override
  String? desktopDirectory() {
    if (_db == null) {
      _db = sqlite3.open(p.join(profile.path, 'manifest.sqlite'))
        ..execute('BEGIN EXCLUSIVE');
      held = true;
    }
    return inner.desktopDirectory();
  }

  void release() {
    final db = _db;
    if (db == null) return;
    _db = null;
    db
      ..execute('COMMIT')
      ..close();
  }
}
