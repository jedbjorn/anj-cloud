import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/state/manifest.dart';

import 'fakes.dart';
import 'openssl_cli.dart' show opensslExecutable;

void main() {
  test(
    'device key, signed CSR and fingerprint persist before enrollment retry',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'anj-identity-test-',
      );
      final store = Manifest(directory);
      final secrets = MemorySecrets();
      final identity = DeviceIdentity(store, secrets);
      try {
        await identity.prepare();
        final key = await secrets.read(identity.privateKeyRef);
        final csr = store.setting('csr');
        final fingerprint = store.setting('fingerprint');
        await identity.prepare();
        expect(await secrets.read(identity.privateKeyRef), key);
        expect(store.setting('csr'), csr);
        expect(store.setting('fingerprint'), fingerprint);
        expect(fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
        final process = await Process.start(opensslExecutable, [
          'req',
          '-verify',
          '-noout',
        ]);
        process.stdin.write(csr);
        await process.stdin.close();
        await process.stdout.drain<void>();
        await process.stderr.drain<void>();
        expect(await process.exitCode, 0);
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'missing key replaces stale CSR while preserving account and origin pins',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'anj-key-recovery-test-',
      );
      final store = Manifest(directory);
      final secrets = MemorySecrets();
      final identity = DeviceIdentity(store, secrets);
      try {
        await identity.prepare();
        final original = store.setting('csr');
        final fingerprint = store.setting('fingerprint');
        store.setSetting('accountUid', 'pinned-user');
        store.setSetting('accountOrigin', 'https://pinned.invalid');
        store.setSetting('certificate', 'obsolete public fixture');
        store.setSetting('certificateExpires', '2099-01-01T00:00:00Z');
        await secrets.delete(identity.privateKeyRef);
        await identity.prepare();
        expect(store.setting('csr'), isNot(original));
        expect(store.setting('fingerprint'), isNot(fingerprint));
        expect(store.setting('certificate'), isNull);
        expect(store.setting('accountUid'), 'pinned-user');
        expect(store.setting('accountOrigin'), 'https://pinned.invalid');
        final replacement = store.setting('csr');
        await identity.prepare();
        expect(store.setting('csr'), replacement);
        expect(store.setting('keyRecovery'), 'new invitation required');
      } finally {
        store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test('an unreadable stored CSR de-enrols only on a proven key mismatch '
      '(PR #50 review L1)', () async {
    final directory = Directory.systemTemp.createTempSync(
      'anj-csr-unreadable-',
    );
    final store = Manifest(directory);
    final secrets = MemorySecrets();
    final identity = DeviceIdentity(store, secrets);
    Future<String> selfSigned(String keyPem) async {
      final keyFile = File('${directory.path}/k.pem')
        ..writeAsStringSync(keyPem);
      final result = await Process.run(opensslExecutable, [
        'req',
        '-x509',
        '-key',
        keyFile.path,
        '-subj',
        '/CN=device',
        '-days',
        '1',
      ]);
      keyFile.deleteSync();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result.stdout as String;
    }

    try {
      await identity.prepare();
      final key = (await secrets.read(identity.privateKeyRef))!;
      final fingerprint = store.setting('fingerprint');
      // A certificate for this key: an unreadable CSR is only replaced.
      final own = await selfSigned(key);
      store.setSetting('certificate', own);
      store.setSetting('csr', 'not a certification request');
      await identity.prepare();
      expect(store.setting('certificate'), own);
      expect(store.setting('keyRecovery'), isNull);
      expect(store.setting('fingerprint'), fingerprint);
      expect(
        store.setting('csr'),
        startsWith('-----BEGIN CERTIFICATE REQUEST'),
      );

      // A certificate for another key proves the mismatch: de-enrolled.
      final other = await Process.run(opensslExecutable, [
        'genpkey',
        '-algorithm',
        'EC',
        '-pkeyopt',
        'ec_paramgen_curve:P-256',
      ]);
      store.setSetting('certificate', await selfSigned(other.stdout as String));
      store.setSetting('csr', 'not a certification request');
      await identity.prepare();
      expect(store.setting('certificate'), isNull);
      expect(store.setting('keyRecovery'), 'new invitation required');
    } finally {
      store.close();
      directory.deleteSync(recursive: true);
    }
  });
}
