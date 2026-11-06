import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/desktop/channel_tray.dart';
import 'package:anj_cloud/platform/macos/keychain_secrets.dart';
import 'package:anj_cloud/platform/macos/macos_desktop_session.dart';
import 'package:anj_cloud/platform/macos/macos_label.dart';
import 'package:anj_cloud/platform/macos/macos_root_location.dart';
import 'package:anj_cloud/platform/macos/macos_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spec #31 M3: the Dart side of the macOS adapters against a faked runner
/// (the `cloud.anj/window`, `cloud.anj/tray`, `cloud.anj/keychain` and
/// `cloud.anj/system` channels) and injected volumes. Runs everywhere; the
/// runner itself is checked on mac-test (tool/macos/session_check.sh and
/// integration_test/macos_adapters_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  final calls = <String, List<MethodCall>>{};
  const channels = [
    'cloud.anj/window',
    'cloud.anj/tray',
    'cloud.anj/keychain',
    'cloud.anj/system',
  ];

  void fakeRunner(String channel, Object? Function(MethodCall call) answer) {
    calls[channel] = [];
    messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
      calls[channel]!.add(call);
      return answer(call);
    });
  }

  /// A runner -> Dart call on [channel]; completes with Dart's decoded reply.
  Future<Object?> fromRunner(
    String channel,
    String method, [
    Object? arguments,
  ]) {
    final reply = Completer<Object?>();
    messenger.handlePlatformMessage(
      channel,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) =>
          reply.complete(data == null ? null : codec.decodeEnvelope(data)),
    );
    return reply.future;
  }

  tearDown(() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  group('window', () {
    test(
      'show and hide go to the runner (which toggles the Dock icon)',
      () async {
        fakeRunner('cloud.anj/window', (_) => null);
        final window = MacosWindow();
        await window.show();
        await window.hide();
        expect(calls['cloud.anj/window']!.map((c) => c.method), [
          'show',
          'hide',
        ]);
      },
    );

    test(
      'the close button is an exit request, as GTK delete is on Linux',
      () async {
        var requests = 0;
        final listener = AppLifecycleListener(
          onExitRequested: () async {
            requests++;
            return AppExitResponse.cancel;
          },
        );
        addTearDown(listener.dispose);
        MacosWindow();
        await fromRunner('cloud.anj/window', 'close');
        expect(requests, 1);
      },
    );

    test('terminate requests take the Quit path once Dart listens', () async {
      final window = MacosWindow();
      // Before main() wires Quit, AppKit is told to terminate at once.
      expect(await fromRunner('cloud.anj/window', 'quit'), false);
      var quits = 0;
      window.onQuit = () => quits++;
      expect(await fromRunner('cloud.anj/window', 'quit'), true);
      expect(quits, 1);
      var activations = 0;
      window.onActivate = () => activations++;
      await fromRunner('cloud.anj/window', 'activate');
      expect(activations, 1);
    });

    test(
      'exit lets AppKit terminate, with a direct exit as fallback',
      () async {
        fakeRunner('cloud.anj/window', (_) => null);
        final exits = <int>[];
        exitProcess = exits.add;
        addTearDown(() => exitProcess = (_) {});
        final window = MacosWindow(fallback: const Duration(milliseconds: 20));
        await window.exit();
        expect(calls['cloud.anj/window']!.single.method, 'exit');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(exits, [0]);
      },
    );
  });

  group('session', () {
    test(
      'menu-bar item: Quit is wired first; Close hides when it exists',
      () async {
        fakeRunner(
          'cloud.anj/tray',
          (call) => call.method == 'start' ? true : null,
        );
        final session = MacosDesktopSession();
        final events = <String>[];
        final tray = await session.startTray(
          onOpen: () => events.add('open'),
          onTogglePause: () => events.add('pause'),
          onQuit: () => events.add('quit'),
        );
        expect(tray, isA<ChannelTray>());
        expect(tray!.hostAvailable, isTrue);
        expect(calls['cloud.anj/tray']!.single.arguments, {
          'tooltip': 'AnJ Cloud',
        });
        await tray.setState(SyncStatus.upToDate, paused: true);
        expect(calls['cloud.anj/tray']!.last.arguments, {
          'status': 'AnJ Cloud: Up to date',
          'paused': true,
        });
        for (final method in ['open', 'togglePause', 'quit']) {
          await fromRunner('cloud.anj/tray', method);
        }
        expect(await fromRunner('cloud.anj/window', 'quit'), true);
        expect(events, ['open', 'pause', 'quit', 'quit']);
        var shown = 0;
        await session.claimActivation('/profile', () => shown++);
        await fromRunner('cloud.anj/window', 'activate');
        expect(shown, 1);
        expect(await session.activateExisting('/profile'), isFalse);
        await tray.close();
      },
    );

    test(
      'no runner tray: no item (Close quits), but Quit still works',
      () async {
        final session = MacosDesktopSession();
        var quits = 0;
        expect(
          await session.startTray(
            onOpen: () {},
            onTogglePause: () {},
            onQuit: () => quits++,
          ),
          isNull,
        );
        expect(await fromRunner('cloud.anj/window', 'quit'), true);
        expect(quits, 1);
        // Without the item there is no reopen hand-off either.
        await session.claimActivation('/profile', () => fail('not claimed'));
        await fromRunner('cloud.anj/window', 'activate');
      },
    );

    test('the profile stays under Application Support', () {
      expect(
        MacosDesktopSession().defaultProfile(
          '/Users/u/Library/Application Support/cloud.anj.anj-cloud',
        ),
        '/Users/u/Library/Application Support/cloud.anj.anj-cloud/anj-cloud/default',
      );
    });
  });

  group('keychain', () {
    test(
      'calls are pinned to the bundle service and the login keychain',
      () async {
        final store = <String, String>{};
        fakeRunner('cloud.anj/keychain', (call) {
          final args = call.arguments as Map;
          final account = args['account'] as String;
          switch (call.method) {
            case 'read':
              return store[account];
            case 'write':
              store[account] = args['value'] as String;
            case 'delete':
              store.remove(account);
            case 'exists':
              return store.containsKey(account);
          }
          return null;
        });
        final secrets = KeychainSecrets();
        expect(await secrets.read('anj-cloud:p:device-key'), isNull);
        await secrets.write('anj-cloud:p:device-key', 'PEM');
        expect(await secrets.read('anj-cloud:p:device-key'), 'PEM');
        expect(await secrets.exists('anj-cloud:p:device-key'), isTrue);
        await secrets.delete('anj-cloud:p:device-key');
        expect(await secrets.exists('anj-cloud:p:device-key'), isFalse);
        final write = calls['cloud.anj/keychain']!.firstWhere(
          (c) => c.method == 'write',
        );
        expect(write.arguments, {
          'service': 'cloud.anj.anj-cloud',
          'account': 'anj-cloud:p:device-key',
          'value': 'PEM',
          'interaction': true,
        });
        final read = calls['cloud.anj/keychain']!.first;
        expect((read.arguments as Map).containsKey('value'), isFalse);
      },
    );

    test('any refusal is Keychain unavailable, with its status', () async {
      fakeRunner(
        'cloud.anj/keychain',
        (_) => throw PlatformException(
          code: 'unavailable',
          message: 'User interaction is not allowed.',
          details: -25308,
        ),
      );
      final secrets = KeychainSecrets(interaction: false);
      await expectLater(
        secrets.read('k'),
        throwsA(
          isA<SecretStoreUnavailable>()
              .having((e) => e.code, 'code', -25308)
              .having((e) => e.message, 'message', keychainUnavailableMessage),
        ),
      );
      await expectLater(
        secrets.write('k', 'v'),
        throwsA(isA<SecretStoreUnavailable>()),
      );
      await expectLater(
        secrets.delete('k'),
        throwsA(isA<SecretStoreUnavailable>()),
      );
      expect(
        (calls['cloud.anj/keychain']!.first.arguments as Map)['interaction'],
        false,
      );
    });

    test(
      'a runner without the channel is unavailable, never "no key"',
      () async {
        await expectLater(
          KeychainSecrets().read('k'),
          throwsA(isA<SecretStoreUnavailable>()),
        );
      },
    );
  });

  group('label', () {
    test('the Computer Name, else the host name without .local', () async {
      fakeRunner('cloud.anj/system', (_) => " Sam’s MacBook Air ");
      expect(await macosDeviceLabel(hostname: 'x.local'), 'Sam’s MacBook Air');
      fakeRunner('cloud.anj/system', (_) => '');
      expect(
        await macosDeviceLabel(hostname: 'Jeds-MacBook-Air.local'),
        'Jeds-MacBook-Air',
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('cloud.anj/system'),
        null,
      );
      expect(await macosDeviceLabel(hostname: 'mac-test.LOCAL'), 'mac-test');
      expect(macosHostLabel('halo'), 'halo');
    });
  });

  group('root location', () {
    const apfs = MacosVolume(
      type: 'apfs',
      local: true,
      mountPoint: '/System/Volumes/Data',
    );
    MacosRootLocation policy([MacosVolume? volume = apfs]) => MacosRootLocation(
      home: '/Users/sam',
      volumeAt: (_) => volume,
      volumeOf: (_) => volume,
    );

    test('~/anj-cloud and external APFS are accepted', () {
      expect(policy().refuseRoot('/Users/sam/anj-cloud'), isNull);
      expect(
        policy().refuseRoot('/Users/sam/Projects/anj-cloud', fd: 3),
        isNull,
      );
      expect(
        policy(
          const MacosVolume(
            type: 'apfs',
            local: true,
            mountPoint: '/Volumes/T7',
          ),
        ).refuseRoot('/Volumes/T7/anj-cloud'),
        isNull,
      );
      // Only the exact protected folders, not look-alikes.
      expect(policy().refuseRoot('/Users/sam/Documents2/anj-cloud'), isNull);
    });

    test(
      'protected folders are refused, in any case and through the firmlink',
      () {
        for (final path in [
          '/Users/sam/Desktop/anj-cloud',
          '/Users/sam/Documents/work/anj-cloud',
          '/Users/sam/downloads/anj-cloud',
          '/System/Volumes/Data/Users/sam/Documents/anj-cloud',
        ]) {
          expect(
            policy().refuseRoot(path),
            contains('macOS protects'),
            reason: path,
          );
        }
        expect(
          policy().refuseRoot('/Users/sam/Desktop/anj-cloud'),
          'macOS protects your Desktop folder, and iCloud may sync it. '
          'Choose another parent folder, such as your home folder.',
        );
      },
    );

    test('other sync providers and Time Machine snapshots are refused', () {
      for (final path in [
        '/Users/sam/Library/Mobile Documents/com~apple~CloudDocs/anj-cloud',
        '/Users/sam/Library/CloudStorage/Dropbox/anj-cloud',
      ]) {
        expect(policy().refuseRoot(path), contains('another sync service'));
      }
      expect(
        policy().refuseRoot(
          '/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/x/anj-cloud',
        ),
        contains('Time Machine snapshot'),
      );
      expect(
        policy(
          const MacosVolume(
            type: 'apfs',
            local: true,
            mountPoint: '/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/m/2026',
          ),
        ).refuseRoot('/Users/sam/anj-cloud', fd: 3),
        contains('Time Machine snapshot'),
      );
    });

    test('network and non-APFS volumes are refused with their type', () {
      expect(
        policy(
          const MacosVolume(
            type: 'smbfs',
            local: false,
            mountPoint: '/Volumes/share',
          ),
        ).refuseRoot('/Volumes/share/anj-cloud'),
        'This folder is on a network volume (smbfs). AnJ Cloud syncs only '
        'folders on a local APFS volume. Choose another parent folder, such '
        'as your home folder.',
      );
      for (final type in ['hfs', 'msdos', 'exfat', 'ntfs']) {
        expect(
          policy(MacosVolume(type: type, local: true, mountPoint: '/Volumes/X'))
              .refuseRoot('/Volumes/X/anj-cloud', fd: 3),
          contains('on a $type volume, not APFS'),
        );
      }
      // An unreadable volume is refused, never assumed.
      expect(
        policy(null).refuseRoot('/Users/sam/anj-cloud'),
        contains('could not be checked'),
      );
    });

    test('the picker reads the nearest existing folder; the engine its fd', () {
      final seenPaths = <String>[];
      final seenFds = <int>[];
      final location = MacosRootLocation(
        home: '/Users/sam',
        volumeAt: (path) {
          seenPaths.add(path);
          return apfs;
        },
        volumeOf: (fd) {
          seenFds.add(fd);
          return apfs;
        },
      );
      location.refuseRoot('/nonexistent-anj-m3/a/anj-cloud');
      location.refuseRoot('/Users/sam/anj-cloud', fd: 7);
      expect(seenPaths, ['/']);
      expect(seenFds, [7]);
    });

    test('struct statfs is read at the Darwin arm64 offsets', () {
      final bytes = Uint8List(MacosVolume.structSize);
      ByteData.sublistView(bytes)
          .setUint32(64, 0x00001000 | 0x1, Endian.little);
      bytes.setAll(72, 'apfs'.codeUnits);
      bytes.setAll(88, utf8.encode('/Volumes/Café'));
      final volume = MacosVolume.fromStatfs(bytes);
      expect(volume.type, 'apfs');
      expect(volume.local, isTrue);
      expect(volume.mountPoint, '/Volumes/Café');
      ByteData.sublistView(bytes).setUint32(64, 0, Endian.little);
      expect(MacosVolume.fromStatfs(bytes).local, isFalse);
    });
  });

  group('add-only keys, read-only and backup volumes (PR #72 review)', () {
    test(
      'a new device key is add-only: a misread "no key" never overwrites',
      () async {
        // The runner holds a key, but a read wrongly reports none.
        final items = <String, String>{};
        var misread = true;
        fakeRunner('cloud.anj/keychain', (call) {
          final args = call.arguments as Map;
          final account = args['account'] as String;
          switch (call.method) {
            case 'read':
              return misread ? null : items[account];
            case 'add':
              if (items.containsKey(account)) {
                throw PlatformException(
                  code: 'unavailable',
                  message: 'An item already exists for this account.',
                  details: -25299,
                );
              }
              items[account] = args['value'] as String;
            case 'write':
              items[account] = args['value'] as String;
          }
          return null;
        });
        final dir = Directory.systemTemp.createTempSync('anj-m3-add-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Manifest(dir)..setSetting('profileId', 'p');
        addTearDown(store.close);
        final identity = DeviceIdentity(store, KeychainSecrets());
        items[identity.privateKeyRef] = 'the real key';
        await expectLater(
          identity.prepare(),
          throwsA(
            isA<SecretStoreUnavailable>().having((e) => e.code, 'code', -25299),
          ),
        );
        expect(items[identity.privateKeyRef], 'the real key');
        expect(
          calls['cloud.anj/keychain']!.map((c) => c.method),
          isNot(contains('write')),
        );
        expect(store.setting('csr'), isNull);
        // With no item there, the add stores the new key.
        items.clear();
        misread = false;
        await identity.prepare();
        expect(items[identity.privateKeyRef], contains('PRIVATE KEY'));
        // The invitation keeps add-or-update.
        await KeychainSecrets().write(identity.invitationRef, 'one');
        await KeychainSecrets().write(identity.invitationRef, 'two');
        expect(items[identity.invitationRef], 'two');
      },
    );

    MacosRootLocation on(MacosVolume volume) => MacosRootLocation(
      home: '/Users/sam',
      volumeAt: (_) => volume,
      volumeOf: (_) => volume,
    );
    const data = MacosVolume(
      type: 'apfs',
      local: true,
      mountPoint: '/System/Volumes/Data',
    );

    test('read-only volumes are refused, the sealed system volume too', () {
      expect(
        on(
          const MacosVolume(
            type: 'apfs',
            local: true,
            mountPoint: '/Volumes/Backup',
            readOnly: true,
          ),
        ).refuseRoot('/Volumes/Backup/anj-cloud', fd: 3),
        'This folder is on a read-only volume. Choose another parent folder, '
        'such as your home folder.',
      );
      expect(
        on(
          const MacosVolume(
            type: 'apfs',
            local: true,
            mountPoint: '/',
            readOnly: true,
          ),
        ).refuseRoot('/anj-cloud'),
        contains('read-only'),
      );
      expect(on(data).refuseRoot('/Users/sam/anj-cloud'), isNull);
    });

    test('Time Machine backup volumes are refused by path and by mount', () {
      for (final path in [
        '/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/x/anj-cloud',
        '/Volumes/.timemachine/ABC/2026-11-04-120000.backup/anj-cloud',
        '/volumes/.TimeMachine/ABC/anj-cloud',
      ]) {
        expect(
          on(data).refuseRoot(path),
          contains('Time Machine'),
          reason: path,
        );
      }
      expect(
        on(
          const MacosVolume(
            type: 'apfs',
            local: true,
            mountPoint: '/Volumes/.timemachine/ABC',
          ),
        ).refuseRoot('/Users/sam/anj-cloud', fd: 3),
        contains('Time Machine'),
      );
    });

    test('the test keychain is passed only when a test names one', () async {
      fakeRunner('cloud.anj/keychain', (_) => null);
      await KeychainSecrets().read('a');
      await KeychainSecrets(testKeychain: '/tmp/k.keychain-db').read('a');
      final args = calls['cloud.anj/keychain']!.map((c) => c.arguments as Map);
      expect(args.first.containsKey('testKeychain'), isFalse);
      expect(args.last['testKeychain'], '/tmp/k.keychain-db');
    });

    test('MNT_RDONLY is read from f_flags', () {
      final bytes = Uint8List(MacosVolume.structSize);
      bytes.setAll(72, 'apfs'.codeUnits);
      ByteData.sublistView(bytes).setUint32(64, 0x00001001, Endian.little);
      expect(MacosVolume.fromStatfs(bytes).readOnly, isTrue);
      ByteData.sublistView(bytes).setUint32(64, 0x00001000, Endian.little);
      expect(MacosVolume.fromStatfs(bytes).readOnly, isFalse);
    });
  });
}
