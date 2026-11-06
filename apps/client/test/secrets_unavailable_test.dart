// Spec #31 M3 on any host: the shared controller's "Keychain unavailable"
// state (no worker, so no network or root work, until Retry), the root
// location refusal before anything is created, and the pairing label clip.
// Linux keeps its behaviour: its keyring never raises SecretStoreUnavailable,
// and its policy and label are the previous ones.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/ports/root_location.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/core/sync/worker.dart';
import 'package:anj_cloud/platform/linux/linux_platform_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A store that refuses every call while [locked], like a locked keychain.
class _LockableSecrets extends MemorySecrets {
  bool locked = true;
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    if (locked) {
      throw const SecretStoreUnavailable('Keychain unavailable.', code: -25308);
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (locked) throw const SecretStoreUnavailable('Keychain unavailable.');
    return super.write(key, value);
  }
}

class _Refuse implements RootLocationPolicy {
  final asked = <String>[];
  @override
  String? refuseRoot(String rootPath, {int? fd}) {
    asked.add(rootPath);
    return 'Not here.';
  }
}

/// On mac-test the Darwin dylib under test (tool/macos/check_macos.sh);
/// on Linux null, so ANJ_ROOTFS_LIBRARY applies as everywhere.
final _library = Platform.environment['ANJ_MACOS_ROOTFS_LIBRARY'];

void main() {
  late Directory fixture;
  setUp(() => fixture = Directory.systemTemp.createTempSync('anj-secrets-'));
  tearDown(() => fixture.deleteSync(recursive: true));

  /// A profile with a root and an unexpired certificate (so the start reads
  /// the device key), but no account binding (so a worker stays offline).
  Future<Directory> enrolledProfile() async {
    final profile = Directory('${fixture.path}/profile');
    final setup = ClientController(
      profile,
      secrets: MemorySecrets(),
      nativeLibrary: _library,
    );
    try {
      await setup.initialize();
      final parent = Directory('${fixture.path}/parent')..createSync();
      await setup.configureRoot(parent.path);
    } finally {
      await setup.stop();
      setup.dispose();
    }
    final store = Manifest(profile);
    store.setSetting('certificate', 'not used offline');
    store.setSetting(
      'certificateExpires',
      DateTime.now().add(const Duration(days: 30)).toIso8601String(),
    );
    store.close();
    return profile;
  }

  test(
    'an unavailable keychain stops before any worker, until Retry',
    () async {
      final profile = await enrolledProfile();
      final secrets = _LockableSecrets();
      final controller = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: _library,
      );
      try {
        await controller.initialize();
        expect(secrets.reads, 1);
        expect(controller.secretsUnavailable, 'Keychain unavailable.');
        expect(controller.message, 'Keychain unavailable.');
        expect(controller.status, SyncStatus.attention);
        // No worker: no state ever replaces the message, nothing is ready.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(controller.message, 'Keychain unavailable.');
        expect(controller.canCreateFolder, isFalse);
        expect(controller.entries, isEmpty);
        // Retry while still locked: the same state, one more read.
        await controller.retrySecrets();
        expect(secrets.reads, 2);
        expect(controller.secretsUnavailable, isNotNull);
        // Unlocked: Retry starts the worker (offline: no account binding).
        secrets.locked = false;
        await controller.retrySecrets();
        expect(controller.secretsUnavailable, isNull);
        // The worker's first state arrives after it reports ready.
        for (var i = 0; i < 100 && !controller.canCreateFolder; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(controller.canCreateFolder, isTrue);
        expect(controller.message, isNot('Keychain unavailable.'));
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );

  test(
    'pairing reports the unavailable keychain, not a pairing failure',
    () async {
      final profile = Directory('${fixture.path}/unpaired');
      final secrets = _LockableSecrets();
      final controller = ClientController(
        profile,
        secrets: secrets,
        nativeLibrary: _library,
      );
      try {
        await controller.initialize();
        // A legacy-format code with a CA file reaches the device key, which
        // the locked store refuses (spec #35's pair(address, code, caPath:)).
        File('${fixture.path}/ca.pem').writeAsStringSync('not used');
        await expectLater(
          controller.pair(
            'https://127.0.0.1:9',
            '0123456789ABCDEFGHJKMNPQRSTVWXYZ',
            caPath: '${fixture.path}/ca.pem',
          ),
          throwsA(isA<SecretStoreUnavailable>()),
        );
        expect(controller.message, 'Keychain unavailable.');
      } finally {
        await controller.stop();
        controller.dispose();
      }
    },
  );

  test('a refused root location creates nothing', () async {
    final profile = Directory('${fixture.path}/refused');
    final policy = _Refuse();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      rootLocation: policy,
      nativeLibrary: _library,
    );
    final parent = Directory('${fixture.path}/parent')..createSync();
    try {
      await controller.initialize();
      await expectLater(
        controller.configureRoot(parent.path),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'Not here.',
          ),
        ),
      );
      expect(policy.asked, ['${parent.resolveSymbolicLinksSync()}/anj-cloud']);
      expect(parent.listSync(), isEmpty);
      expect(controller.root, isNull);
      final store = Manifest(profile);
      expect(store.setting('root'), isNull);
      store.close();
    } finally {
      await controller.stop();
      controller.dispose();
    }
  });

  test('the pairing label is clipped as the gateway counts', () {
    expect(pairingLabel('halo'), 'halo');
    expect(pairingLabel('a' * 90), 'a' * 80);
    // Code points, not UTF-16 units: an emoji is never split.
    final name = '${'b' * 79}\u{1F600}x';
    expect(pairingLabel(name), '${'b' * 79}\u{1F600}');
    expect(pairingLabel("Sam’s\nMac\u007F"), 'Sam’sMac');
  });

  test('Linux keeps its location rules and host-name label', () async {
    const linux = LinuxPlatformAdapters();
    expect(
      linux.rootLocationPolicy().refuseRoot('/home/u/Documents/x'),
      isNull,
    );
    expect(await linux.deviceLabel(), Platform.localHostname);
  });

  test(
    'the engine checks where the root really is, before opening it',
    () async {
      // A root path whose parent was swapped for a symlink into a refused
      // folder: the policy sees the resolved path and nothing is opened.
      final refused = Directory('${fixture.path}/Documents/moved/anj-cloud')
        ..createSync(recursive: true);
      Link('${fixture.path}/swapped')
          .createSync('${fixture.path}/Documents/moved');
      final profile = Directory('${fixture.path}/engine-profile')..createSync();
      final store = Manifest(profile);
      store.setSetting('root', '${fixture.path}/swapped/anj-cloud');
      store.setSetting('staging', '${fixture.path}/swapped/.anj-cloud-staging');
      store.close();
      final policy = _RefuseUnder(
        Directory('${fixture.path}/Documents').resolveSymbolicLinksSync(),
      );
      final output = ReceivePort();
      final events = StreamIterator<dynamic>(output);
      await Isolate.spawn(syncWorker, {
        'output': output.sendPort,
        'profile': profile.path,
        'privateKey': null,
        'nativeLibrary': _library,
        'rootLocation': policy,
      });
      try {
        expect(
          await events.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        final event = events.current as Map;
        expect(event['event'], 'fatal');
        expect(event['message'], 'Paused: Not here. No files were changed.');
        expect(
          Directory('${fixture.path}/Documents/moved/.anj-cloud-staging')
              .existsSync(),
          isFalse,
        );
        expect(refused.listSync(), isEmpty);
      } finally {
        await events.cancel();
        output.close();
      }
    },
  );
}

/// Refuses every root under [folder], and records what it was asked.
class _RefuseUnder implements RootLocationPolicy {
  _RefuseUnder(this.folder);
  final String folder;
  @override
  String? refuseRoot(String rootPath, {int? fd}) =>
      rootPath.startsWith('$folder/') ? 'Not here.' : null;
}
