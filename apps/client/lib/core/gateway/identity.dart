import 'dart:convert';
import 'dart:io';

import '../ports/secret_store.dart';
import '../state/manifest.dart';
import '../local/root_tree.dart';
import 'device_crypto.dart';

class DeviceIdentity {
  DeviceIdentity(
    this.manifest,
    this.secrets, {
    this.crypto = const DartDeviceCrypto(),
  });
  final Manifest manifest;
  final SecretStore secrets;
  final DeviceCrypto crypto;
  String get id => manifest.setting('profileId')!;
  String get privateKeyRef => 'anj-cloud:$id:device-key';
  String get invitationRef => 'anj-cloud:$id:invitation';

  Future<void> prepare() async {
    if (manifest.setting('profileId') == null) {
      manifest.setSetting('profileId', uniqueId());
    }
    var key = await secrets.read(privateKeyRef);
    final hadIdentity =
        manifest.setting('csr') != null ||
        manifest.setting('certificate') != null;
    if (key == null) {
      key = await crypto.generateKey();
      // Never over an existing key, where the store can refuse that.
      final store = secrets;
      if (store is AddOnlySecretStore) {
        await store.add(privateKeyRef, key);
      } else {
        await store.write(privateKeyRef, key);
      }
      if (await secrets.read(privateKeyRef) != key) {
        throw const FileSystemException(
          'Keyring did not retain the device key.',
        );
      }
    }
    final fingerprint = keyFingerprint(await _keyInfo(key));
    var csr = manifest.setting('csr');
    // The stored CSR's key, or null when it cannot be read.
    String? requestKey;
    if (csr != null) {
      try {
        requestKey = keyFingerprint(crypto.requestPublicKeyInfo(csr));
      } catch (_) {
        requestKey = null;
      }
    }
    final matches = requestKey == fingerprint;
    // De-enrol only on a proven key mismatch (PR #50 review L1): a readable
    // CSR for another key, or, when the CSR cannot be read, a readable
    // certificate for another key. An unreadable CSR beside a certificate
    // for this key only gets a fresh CSR; the certificate stays.
    var mismatch = requestKey != null && requestKey != fingerprint;
    if (requestKey == null) {
      final certificate = manifest.setting('certificate');
      if (certificate != null) {
        try {
          mismatch =
              keyFingerprint(crypto.certificate(certificate).publicKeyInfo) !=
              fingerprint;
        } catch (_) {
          mismatch = false;
        }
      } else {
        mismatch = csr != null;
      }
    }
    if (!matches) {
      csr = await _guard(
        () => crypto.certificationRequest(key!, commonName: id),
      );
    }
    manifest.transaction(() {
      manifest.setSetting('csr', csr!);
      manifest.setSetting('fingerprint', fingerprint);
      if (hadIdentity && mismatch) {
        manifest.deleteSetting('certificate');
        manifest.deleteSetting('certificateExpires');
        manifest.setSetting('keyRecovery', 'new invitation required');
      }
      // Account UID and origin deliberately survive key recovery.
    });
  }

  Future<DateTime> verifyCertificate(
    String certificate,
    String fingerprint,
  ) async {
    if (fingerprint != manifest.setting('fingerprint')) {
      throw const FormatException('Pairing fingerprint mismatch.');
    }
    final DeviceCertificate parsed;
    try {
      parsed = crypto.certificate(certificate);
    } on FormatException {
      throw const FormatException('Device certificate could not be read.');
    }
    if (keyFingerprint(parsed.publicKeyInfo) != fingerprint) {
      throw const FormatException(
        'Certificate does not match this device key.',
      );
    }
    final expires = parsed.notAfter;
    if (!expires.isAfter(DateTime.now().toUtc())) {
      throw const FormatException(
        'Device certificate has expired. Re-pair this device.',
      );
    }
    return expires;
  }

  /// The stored key's public half. A key the code cannot read fails like
  /// the OpenSSL CLI did: a generic error that never echoes key material.
  Future<List<int>> _keyInfo(String key) =>
      _guard(() => crypto.publicKeyInfo(key));

  static Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FormatException {
      throw const FileSystemException(
        'Device key operation failed. No key material is logged.',
      );
    }
  }

  bool get enrolled =>
      manifest.setting('certificate') != null &&
      DateTime.tryParse(manifest.setting('certificateExpires') ?? '')
              ?.isAfter(DateTime.now()) ==
          true;
  Future<SecurityContext> context(
    File ca, {
    bool clientIdentity = true,
  }) async =>
      contextFor(await ca.readAsBytes(), clientIdentity: clientIdentity);

  /// [context] for a trust anchor already in memory: the household CA a
  /// pinned code verified (spec #35), before it is stored.
  Future<SecurityContext> contextFor(
    List<int> ca, {
    bool clientIdentity = true,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(ca);
    if (clientIdentity && enrolled) {
      final key = await secrets.read(privateKeyRef);
      if (key == null) {
        throw const FileSystemException(
          'Device key unavailable. Unlock the keyring or re-pair.',
        );
      }
      context.usePrivateKeyBytes(utf8.encode(key));
      context.useCertificateChainBytes(
        utf8.encode(manifest.setting('certificate')!),
      );
    }
    return context;
  }
}
