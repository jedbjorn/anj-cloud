// Opt-in, against a disposable review stack only (deploy/dev.py project
// anj-cloud-review-<tag>). Skipped unless ANJ_REVIEW_STACK_CONFIG names a
// private JSON file:
//   {"repo": checkout whose deploy/.local holds the stack and access venv,
//    "project": "anj-cloud-review-<tag>", "port": 8861,
//    "uid": "anj-fixture-alice", "state": absent-or-owned scratch directory,
//    "phase": "legacy" | "current"}
//
// Spec #28 U1 acceptance row 2. Phase "legacy" runs this same file from a
// checkout of the pre-U1 client (OpenSSL CLI identity) and pairs a device.
// Phase "current" runs from the U1 checkout: the legacy device keeps its key,
// CSR, fingerprint and certificate, authenticates and renews with no re-pair,
// and a new device enrols, authenticates and renews with in-process crypto.
// Only this file's operator calls (test actor, never lib/) sign certificates.
//
// Uses only APIs present before and after U1, so the legacy phase compiles.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/gateway/identity.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/core/state/manifest.dart';

void main() {
  final configPath = Platform.environment['ANJ_REVIEW_STACK_CONFIG'];
  test(
    'device crypto enrols, authenticates and renews against a review stack',
    () async {
      final config = jsonDecode(
        File(configPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final project = config['project'] as String;
      if (!RegExp(r'^anj-cloud-review-[a-z0-9-]+$').hasMatch(project)) {
        throw StateError('Use a disposable anj-cloud-review-<tag> stack.');
      }
      final repo = config['repo'] as String;
      final port = config['port'].toString();
      final uid = config['uid'] as String;
      if (!RegExp(r'^anj-fixture-[a-z0-9-]+$').hasMatch(uid)) {
        throw StateError('Use a synthetic fixture account.');
      }
      final phase = config['phase'] as String;
      final state = Directory(config['state'] as String)
        ..createSync(recursive: true);
      final origin = Uri.parse('https://127.0.0.1:$port');
      final ca = File('$repo/deploy/.local/$project/operator/issuer.crt');
      final secrets = _FileSecrets(File('${state.path}/secrets.json'));
      final evidence = File('${state.path}/$phase.json');
      final record = <String, Object?>{'phase': phase, 'origin': '$origin'};

      Future<Map<String, dynamic>> operator(List<String> arguments) async {
        final result = await Process.run(
          '$repo/deploy/.local/access-venv/bin/python',
          [
            '-m',
            'deploy.access_operator',
            '--project',
            project,
            '--port',
            port,
            ...arguments,
          ],
          workingDirectory: repo,
        );
        if (result.exitCode != 0) {
          throw StateError(
            'Operator ${arguments.first} failed (exit ${result.exitCode}); output withheld.',
          );
        }
        return jsonDecode(result.stdout as String) as Map<String, dynamic>;
      }

      // The same requests ClientController.pair makes.
      Future<Map<String, Object?>> enrol(String name) async {
        final store = Manifest(Directory('${state.path}/$name')..createSync());
        PairingClient? client;
        try {
          final identity = DeviceIdentity(store, secrets);
          await identity.prepare();
          final csr = store.setting('csr')!;
          final fingerprint = store.setting('fingerprint')!;
          final invitation = await operator([
            'invite',
            uid,
            '--rights',
            'write',
          ]);
          final code = invitation['code'] as String;
          client = PairingClient(
            origin,
            await identity.context(ca, clientIdentity: false),
          );
          final pending = await client.enroll(code, csr, label: 'u1 $name');
          expect(pending['state'], 'pending');
          expect(pending['fingerprint'], fingerprint);
          final approval = await operator([
            'approve',
            invitation['id'] as String,
            '--fingerprint',
            fingerprint,
          ]);
          final approved = await client.enroll(code, csr);
          expect(approved['state'], 'approved');
          final certificate = approved['certificate'] as String;
          final expiry = await identity.verifyCertificate(
            certificate,
            approved['fingerprint'] as String,
          );
          store.transaction(() {
            store.setSetting('certificate', certificate);
            store.setSetting('certificateExpires', expiry.toIso8601String());
            store.setSetting('accountUid', approved['uid'] as String);
            store.setSetting('accountOrigin', origin.origin);
            store.setSetting('deviceId', approved['device_id'] as String);
            store.setSetting('server', '$origin');
            store.setSetting('ca', ca.path);
          });
          expect(approved['device_id'], approval['device_id']);
          return {
            'device': approved['device_id'],
            'fingerprint': fingerprint,
            'csr_sha256': _digest(csr),
            'expires': expiry.toIso8601String(),
          };
        } finally {
          client?.client.close(force: true);
          store.close();
        }
      }

      // Mutual TLS with the stored key and current certificate.
      Future<int> authenticate(String name) async {
        final store = Manifest(Directory('${state.path}/$name'));
        try {
          final identity = DeviceIdentity(store, secrets);
          expect(identity.enrolled, isTrue);
          final cloud = DavCloud(origin, await identity.context(ca));
          try {
            return (await cloud.snapshot()).length;
          } finally {
            cloud.close();
          }
        } finally {
          store.close();
        }
      }

      Future<Map<String, Object?>> renew(String name) async {
        final store = Manifest(Directory('${state.path}/$name'));
        try {
          final identity = DeviceIdentity(store, secrets);
          final before = store.setting('certificate');
          final reissued = await operator([
            'reissue',
            store.setting('deviceId')!,
            '--force',
          ]);
          expect(reissued['state'], isNot('failed'));
          final key = (await secrets.read(identity.privateKeyRef))!;
          final first = await CertificatePickup(store, key).run();
          expect(first.outcome, PickupOutcome.renewed);
          expect(store.setting('certificate'), isNot(before));
          final second = await CertificatePickup(store, key).run();
          expect(second.outcome, PickupOutcome.unchanged);
          return {
            'renewed_expires': first.expires.toIso8601String(),
            'certificate_sha256': _digest(store.setting('certificate')!),
          };
        } finally {
          store.close();
        }
      }

      if (phase == 'legacy') {
        record['legacy'] = await enrol('legacy');
        record['legacy_entries'] = await authenticate('legacy');
      } else if (phase == 'current') {
        final legacy =
            (jsonDecode(File('${state.path}/legacy.json').readAsStringSync())
                    as Map)['legacy']
                as Map;
        // Existing device: nothing re-pairs and nothing is regenerated.
        final store = Manifest(Directory('${state.path}/legacy'));
        try {
          final identity = DeviceIdentity(store, secrets);
          final key = await secrets.read(identity.privateKeyRef);
          await identity.prepare();
          expect(await secrets.read(identity.privateKeyRef), key);
          expect(store.setting('fingerprint'), legacy['fingerprint']);
          expect(_digest(store.setting('csr')!), legacy['csr_sha256']);
          expect(store.setting('keyRecovery'), isNull);
          expect(store.setting('certificate'), isNotNull);
        } finally {
          store.close();
        }
        record['legacy_entries'] = await authenticate('legacy');
        record['legacy_renewal'] = await renew('legacy');
        record['legacy_entries_after_renewal'] = await authenticate('legacy');
        // New device with in-process key generation and CSR.
        record['fresh'] = await enrol('fresh');
        record['fresh_entries'] = await authenticate('fresh');
        record['fresh_renewal'] = await renew('fresh');
        record['fresh_entries_after_renewal'] = await authenticate('fresh');
      } else {
        throw StateError('Unknown phase.');
      }
      evidence.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(record),
      );
    },
    skip: configPath == null
        ? 'Opt-in: set ANJ_REVIEW_STACK_CONFIG for a review stack'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

// Evidence carries digests, never certificates, CSRs or keys.
String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

class _FileSecrets implements SecretStore {
  _FileSecrets(this.file);
  final File file;
  Map<String, dynamic> _all() => file.existsSync()
      ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
      : {};
  void _save(Map<String, dynamic> values) {
    file.writeAsStringSync(jsonEncode(values));
    Process.runSync('chmod', ['600', file.path]);
  }

  @override
  Future<String?> read(String key) async => _all()[key] as String?;
  @override
  Future<void> write(String key, String value) async =>
      _save({..._all(), key: value});
  @override
  Future<void> delete(String key) async => _save(_all()..remove(key));
}
