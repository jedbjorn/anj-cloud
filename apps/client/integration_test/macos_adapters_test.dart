// Spec #31 M3 on mac-test, inside the real app with its Swift runner
// (tool/macos/check_m3.sh runs it; never on the VM host). The session is chosen
// at build time:
//
//   --dart-define=ANJ_M3_SESSION=gui   from a gui/<uid> launchd job: the
//                                      login keychain is reachable
//   --dart-define=ANJ_M3_SESSION=ssh   straight from SSH: it is not
//   --dart-define=ANJ_M3_FAT=<dir>     a mounted non-APFS (FAT) volume
//   --dart-define=ANJ_M3_FOREIGN=<acct> an item another program created
//                                      (the post-update case), gui only
//   --dart-define=ANJ_M3_HOME_ROOT=1   also create and remove ~/anj-cloud
//
// Keychain items use service cloud.anj.anj-cloud and accounts containing
// "anj-test-m3", and are deleted here; tool/macos/keychain_cleanup.sh
// removes any a failed run leaves.
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/macos/keychain_secrets.dart';
import 'package:anj_cloud/platform/macos/macos_desktop_session.dart';
import 'package:anj_cloud/platform/macos/macos_label.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/macos/macos_root_location.dart';
import 'package:anj_cloud/platform/macos/macos_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const session = String.fromEnvironment('ANJ_M3_SESSION');
const fatVolume = String.fromEnvironment('ANJ_M3_FAT');
const foreignAccount = String.fromEnvironment('ANJ_M3_FOREIGN');
const homeRoot = bool.fromEnvironment('ANJ_M3_HOME_ROOT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final home = Platform.environment['HOME']!;
  final run = DateTime.now().microsecondsSinceEpoch;
  late Directory fixture;
  setUpAll(() {
    if (session != 'gui' && session != 'ssh') {
      throw StateError('Build with --dart-define=ANJ_M3_SESSION=gui|ssh');
    }
    fixture = Directory.systemTemp.createTempSync('anj-m3-');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  group('keychain ($session session)', () {
    final secrets = KeychainSecrets();
    final account = 'anj-test-m3-$run';

    test('read, write, overwrite and delete in the login keychain', () async {
      if (session == 'ssh') {
        // From SSH the login keychain is listed but locked and not
        // writable (keychain_probe.sh, run 2): a missing item is truly
        // missing (attributes are searchable while locked), a write is
        // refused. An existing item is unavailable (the foreign-item test).
        expect(await secrets.read(account), isNull);
        await expectLater(
          secrets.write(account, 'x'),
          throwsA(isA<SecretStoreUnavailable>()),
        );
        return;
      }
      try {
        expect(await secrets.read(account), isNull);
        expect(await secrets.exists(account), isFalse);
        await secrets.write(account, 'first');
        expect(await secrets.read(account), 'first');
        await secrets.write(account, 'second');
        expect(await secrets.read(account), 'second');
        expect(await secrets.exists(account), isTrue);
        // Its own item reads without UI too (no dialog for the creator).
        expect(
          await KeychainSecrets(interaction: false).read(account),
          'second',
        );
      } finally {
        await secrets.delete(account);
      }
      expect(await secrets.exists(account), isFalse);
      expect(await secrets.read(account), isNull);
      await secrets.delete(account); // deleting a missing item is fine
    });

    test('the device key lives only in the keychain (custody)', () async {
      if (session == 'ssh') return;
      final profile = Directory('${fixture.path}/custody')..createSync();
      final store = Manifest(profile);
      store.setSetting('profileId', 'anj-test-m3-custody-$run');
      final identity = DeviceIdentity(store, secrets);
      // The key's name, taken while the manifest is open (it is closed
      // before the profile files are scanned).
      final keyRef = identity.privateKeyRef;
      var open = true;
      try {
        await identity.prepare();
        final key = await secrets.read(keyRef);
        expect(key, contains('PRIVATE KEY'));
        expect(store.setting('csr'), contains('CERTIFICATE REQUEST'));
        store.close();
        open = false;
        // No file in the profile holds the key: not its PEM armour, not
        // any line of its base64 body.
        final body = key!
            .split('\n')
            .where((line) => line.isNotEmpty && !line.startsWith('-----'))
            .toList();
        for (final file
            in profile.listSync(recursive: true).whereType<File>()) {
          final text = String.fromCharCodes(file.readAsBytesSync());
          expect(text, isNot(contains('PRIVATE KEY')), reason: file.path);
          for (final line in body) {
            expect(text, isNot(contains(line)), reason: file.path);
          }
        }
      } finally {
        if (open) store.close();
        await secrets.delete(keyRef);
      }
    });

    // A dedicated keychain file through the runner's Debug-only override
    // (ANJ_TEST_SEAMS): the login keychain is never locked or touched.
    test('a locked keychain is unavailable, never "no key"', () async {
      if (session == 'ssh') return;
      final path = '${fixture.path}/anj-test-m3-$run.keychain-db';
      final password = '${Random.secure().nextInt(1 << 32)}-$run';
      Future<void> security(List<String> args) async {
        final result = await Process.run('/usr/bin/security', args);
        expect(
          result.exitCode,
          0,
          reason: 'security ${args.first}: ${result.stderr}',
        );
      }

      await security(['create-keychain', '-p', password, path]);
      try {
        final open = KeychainSecrets(testKeychain: path);
        final quiet = KeychainSecrets(testKeychain: path, interaction: false);
        final account = 'anj-test-m3-locked-$run';
        await open.add(account, 'held');
        expect(await quiet.read(account), 'held');
        expect(await quiet.read('anj-test-m3-absent-$run'), isNull);
        await security(['lock-keychain', path]);
        // Locked: the existing item is unavailable, never missing, and an
        // add over it is refused too.
        await expectLater(
          quiet.read(account),
          throwsA(isA<SecretStoreUnavailable>()),
        );
        await expectLater(
          quiet.add(account, 'replacement'),
          throwsA(isA<SecretStoreUnavailable>()),
        );
        // Recorded, not gated: what a missing item reads as while locked.
        try {
          final missing = await quiet.read('anj-test-m3-absent-$run');
          debugPrint('info  locked keychain, missing item: read $missing');
        } on SecretStoreUnavailable catch (error) {
          debugPrint('info  locked keychain, missing item: $error');
        }
        await security(['unlock-keychain', '-p', password, path]);
        expect(await quiet.read(account), 'held');
      } finally {
        await Process.run('/usr/bin/security', ['delete-keychain', path]);
      }
      expect(File(path).existsSync(), isFalse);
      final list = await Process.run('/usr/bin/security', [
        'list-keychains',
        '-d',
        'user',
      ]);
      expect('${list.stdout}', isNot(contains('anj-test-m3-')));
    });

    test(
      'an item this build does not own is unavailable without UI, unchanged',
      () async {
        if (foreignAccount.isEmpty) return;
        final quiet = KeychainSecrets(interaction: false);
        // Both sessions: an existing item is never read as missing (from
        // SSH there is no login keychain to read it from at all).
        await expectLater(
          quiet.read(foreignAccount),
          throwsA(isA<SecretStoreUnavailable>()),
        );
        if (session == 'ssh') return;
        // Still there (check_m3.sh reads its value back with its creator).
        expect(await quiet.exists(foreignAccount), isTrue);
      },
    );
  });

  test('the pairing label is the Computer Name', () async {
    final scutil = await Process.run('/usr/sbin/scutil', [
      '--get',
      'ComputerName',
    ]);
    final label = await macosDeviceLabel();
    expect(label, '${scutil.stdout}'.trim());
    expect(pairingLabel(label), label);
  });

  group('root location', () {
    test('the home folder is local APFS; ~/anj-cloud is accepted', () {
      final volume = macosVolumeAt(home)!;
      expect(volume.type, 'apfs');
      expect(volume.local, isTrue);
      expect(MacosRootLocation().refuseRoot('$home/anj-cloud'), isNull);
      final fs = const MacosPlatformAdapters().rootFilesystem();
      final fd = fs.openRoot(fixture.path);
      try {
        expect(macosVolumeOf(fd)!.type, 'apfs');
        expect(MacosRootLocation().refuseRoot(fixture.path, fd: fd), isNull);
      } finally {
        fs.closeFd(fd);
      }
    });

    test('protected folders are refused without touching them', () {
      for (final name in ['Desktop', 'Documents', 'Downloads']) {
        expect(
          MacosRootLocation().refuseRoot('$home/$name/anj-cloud'),
          contains('macOS protects'),
        );
      }
    });

    test('a FAT volume is refused by the picker and the engine', () async {
      if (fatVolume.isEmpty) return;
      final volume = macosVolumeAt(fatVolume)!;
      expect(volume.type, 'msdos');
      final controller = ClientController(
        Directory('${fixture.path}/fat-profile'),
      );
      try {
        await controller.initialize();
        await expectLater(
          controller.configureRoot(fatVolume),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.message,
              'message',
              contains('msdos volume, not APFS'),
            ),
          ),
        );
        expect(Directory('$fatVolume/anj-cloud').existsSync(), isFalse);
      } finally {
        await controller.stop();
        controller.dispose();
      }
      final fs = const MacosPlatformAdapters().rootFilesystem();
      final fd = fs.openRoot(fatVolume);
      try {
        expect(
          MacosRootLocation().refuseRoot('$fatVolume/anj-cloud', fd: fd),
          contains('not APFS'),
        );
      } finally {
        fs.closeFd(fd);
      }
    });

    test('~/anj-cloud is created with no privacy prompt', () async {
      if (!homeRoot || Directory('$home/anj-cloud').existsSync()) return;
      final id = 'anj-test-m3-$run';
      final tree = RootTree.setup(
        home,
        id,
        const MacosPlatformAdapters().rootFilesystem(),
      );
      try {
        expect(tree.root.path, '$home/anj-cloud');
        expect(Directory('$home/anj-cloud/Documents').existsSync(), isTrue);
      } finally {
        tree.close();
        Directory('$home/anj-cloud').deleteSync(recursive: true);
        final staging = Directory('$home/.anj-cloud-$id');
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
    });
  });

  // The menu bar and window need the GUI session (WindowServer).
  group('menu bar and window (real runner)', skip: session != 'gui', () {
    late MacosDesktopSession desktop;
    late MacosWindow window;
    final events = <String>[];
    Future<Map> state() async =>
        await window.channel.invokeMethod<Map>('debugPerform', 'state') ?? {};

    setUpAll(() {
      desktop = MacosDesktopSession();
      window = desktop.window() as MacosWindow;
    });

    test('the item, its template icon and the Linux menu', () async {
      final tray = await desktop.startTray(
        onOpen: () => events.add('open'),
        onTogglePause: () => events.add('pause'),
        onQuit: () => events.add('quit'),
      );
      expect(tray, isNotNull);
      await tray!.setState(SyncStatus.upToDate, paused: false);
      var now = await state();
      expect(now['statusItem'], isTrue);
      expect(now['statusImage'], isTrue);
      expect(now['menu'], [
        'AnJ Cloud: Up to date',
        '',
        'Open AnJ Cloud',
        'Pause sync',
        '',
        'Quit AnJ Cloud',
      ]);
      // The real menu items reach Dart.
      for (final item in ['open', 'togglePause']) {
        expect(
          await window.channel.invokeMethod('debugPerform', 'statusMenu:$item'),
          isTrue,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(events, ['open', 'pause']);
      await tray.setState(SyncStatus.paused, paused: true);
      now = await state();
      expect((now['menu'] as List)[3], 'Resume sync');
    });

    test('hide drops the window and Dock icon; show restores both', () async {
      await window.hide();
      var now = await state();
      expect(now['windowVisible'], isFalse);
      expect(now['activationPolicy'], 'accessory');
      await window.show();
      now = await state();
      expect(now['windowVisible'], isTrue);
      expect(now['activationPolicy'], 'regular');
    });

    test('the close button arrives as an exit request', () async {
      var requests = 0;
      final listener = AppLifecycleListener(
        onExitRequested: () async {
          requests++;
          return AppExitResponse.cancel;
        },
      );
      try {
        expect(
          await window.channel.invokeMethod('debugPerform', 'window:close'),
          isTrue,
        );
        for (var i = 0; i < 50 && requests == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(requests, 1);
        expect((await state())['windowVisible'], isTrue);
      } finally {
        listener.dispose();
      }
    });
  });
}
