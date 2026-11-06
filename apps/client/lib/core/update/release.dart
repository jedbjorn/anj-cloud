/// The client side of the gateway's update feed (spec #28 G1, spec #37
/// U-core, decisions #108 Q6 and #159): the release manifest the household
/// server serves over this device's paired mTLS connection, the household
/// release key built into desktop apps, and the reasons an update is
/// refused. The gateway only stores what the operator published; the client
/// verifies everything before it offers to install.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ports/package_installer.dart';
import 'ed25519.dart';

/// The Android feed target (spec #28 A7; its trust is the APK signer).
const androidReleaseTarget = 'android-arm64';

/// Desktop feed targets: trusted through the household release key.
const linuxReleaseTarget = 'linux-x86_64';
const macosReleaseTarget = 'macos-arm64';
const windowsReleaseTarget = 'windows-x64';
const desktopReleaseTargets = {
  linuxReleaseTarget,
  macosReleaseTarget,
  windowsReleaseTarget,
};

/// A release manifest, checked with the gateway's own rule
/// (`services/access/release_manifest.py`): the same fields, patterns and
/// ranges. Android manifests carry [signerSha256]; desktop manifests carry
/// [keyId] and [signature] (and optionally [minClientVersionCode]).
class ReleaseManifest {
  const ReleaseManifest({
    required this.target,
    required this.version,
    required this.versionCode,
    required this.size,
    required this.sha256,
    this.signerSha256,
    this.keyId,
    this.signature,
    this.minClientVersionCode,
  });

  final String target;
  final String version;
  final int versionCode;
  final int size;
  final String sha256;

  /// Android: SHA-256 of the APK signing certificate.
  final String? signerSha256;

  /// Desktop: the household release key's id and its Ed25519 signature
  /// (base64) over [signedMessage].
  final String? keyId;
  final String? signature;

  /// Desktop, optional and unsigned: the lowest version the household still
  /// supports. It only labels an older client "Update required".
  final int? minClientVersionCode;

  bool get desktop => desktopReleaseTargets.contains(target);

  static const maxPackage = 512 * 1024 * 1024;
  static const maxVersionCode = 2100000000;
  static final _version = RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$');
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final _keyId = RegExp(r'^[0-9a-f]{16}$');
  static final _signature = RegExp(r'^[A-Za-z0-9+/]{86}==$');
  static const _android = {
    'target',
    'version',
    'version_code',
    'size',
    'sha256',
    'signer_sha256',
  };
  static const _desktop = {
    'target',
    'version',
    'version_code',
    'size',
    'sha256',
    'key_id',
    'signature',
    'min_client_version_code',
  };

  /// The manifest for [target], or a [FormatException] naming the first
  /// field that breaks the rule. Never trusted further than this: the
  /// signature, bytes and version are verified separately.
  factory ReleaseManifest.fromJson(Object? data, String target) {
    if (data is! Map) {
      throw const FormatException('The update record is not a JSON object.');
    }
    final desktop = desktopReleaseTargets.contains(target);
    final allowed = desktop ? _desktop : _android;
    if (data.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('The update record has unexpected fields.');
    }
    if (data['target'] != target) {
      throw const FormatException(
        'The update record is for another device type.',
      );
    }
    final version = data['version'];
    final code = data['version_code'];
    final size = data['size'];
    final sha = data['sha256'];
    if (version is! String || !_version.hasMatch(version)) {
      throw const FormatException('The update record has an invalid version.');
    }
    if (code is! int || code < 1 || code > maxVersionCode) {
      throw const FormatException(
        'The update record has an invalid version code.',
      );
    }
    if (size is! int || size < 1 || size > maxPackage) {
      throw const FormatException('The update record has an invalid size.');
    }
    if (sha is! String || !_sha256.hasMatch(sha)) {
      throw const FormatException('The update record has an invalid SHA-256.');
    }
    if (!desktop) {
      final signer = data['signer_sha256'];
      if (signer is! String || !_sha256.hasMatch(signer)) {
        throw const FormatException('The update record has an invalid signer.');
      }
      return ReleaseManifest(
        target: target,
        version: version,
        versionCode: code,
        size: size,
        sha256: sha,
        signerSha256: signer,
      );
    }
    final keyId = data['key_id'];
    final signature = data['signature'];
    final floor = data['min_client_version_code'];
    if (keyId is! String || !_keyId.hasMatch(keyId)) {
      throw const FormatException('The update record has an invalid key id.');
    }
    if (signature is! String || !_signature.hasMatch(signature)) {
      throw const FormatException(
        'The update record has an invalid signature.',
      );
    }
    if (floor != null && (floor is! int || floor < 1 || floor > code)) {
      throw const FormatException(
        'The update record has an invalid minimum version.',
      );
    }
    return ReleaseManifest(
      target: target,
      version: version,
      versionCode: code,
      size: size,
      sha256: sha,
      keyId: keyId,
      signature: signature,
      minClientVersionCode: floor as int?,
    );
  }

  Map<String, Object> toJson() => {
    'target': target,
    'version': version,
    'version_code': versionCode,
    'size': size,
    'sha256': sha256,
    'signer_sha256': ?signerSha256,
    'key_id': ?keyId,
    'signature': ?signature,
    'min_client_version_code': ?minClientVersionCode,
  };

  /// The exact bytes the household release key signs; byte for byte
  /// `signed_message` in `services/access/release_manifest.py`.
  List<int> get signedMessage => utf8.encode(
    'anj-cloud release v1\n'
    'target $target\n'
    'version $version\n'
    'version_code $versionCode\n'
    'size $size\n'
    'sha256 $sha256\n'
    'key_id $keyId\n',
  );

  @override
  bool operator ==(Object other) =>
      other is ReleaseManifest &&
      other.target == target &&
      other.version == version &&
      other.versionCode == versionCode &&
      other.size == size &&
      other.sha256 == sha256 &&
      other.signerSha256 == signerSha256 &&
      other.keyId == keyId &&
      other.signature == signature &&
      other.minClientVersionCode == minClientVersionCode;

  @override
  int get hashCode => Object.hash(
    target,
    version,
    versionCode,
    size,
    sha256,
    signerSha256,
    keyId,
    signature,
    minClientVersionCode,
  );
}

/// The household release key's public half, built into every desktop app
/// (`assets/release/household-release-key.pub`, decision #159).
class ReleaseKey {
  ReleaseKey(List<int> raw)
    : raw = List.unmodifiable(raw),
      id = sha256.convert(raw).toString().substring(0, 16);

  /// The 32-byte Ed25519 public key.
  final List<int> raw;

  /// The first 16 hex characters of the key's SHA-256 (the manifest's
  /// `key_id`).
  final String id;

  static const asset = 'assets/release/household-release-key.pub';

  /// The key in a key file's [text]: `#` comments and at most one
  /// `ed25519 <base64>` line. Null when the file holds no key (a build made
  /// before the household key existed); [FormatException] when malformed.
  static ReleaseKey? parse(String text) {
    final lines = const LineSplitter()
        .convert(text)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    if (lines.isEmpty) return null;
    if (lines.length != 1 || !lines.single.startsWith('ed25519 ')) {
      throw const FormatException('Malformed release key file.');
    }
    final List<int> raw;
    try {
      raw = base64.decode(lines.single.substring(8).trim());
    } on FormatException {
      throw const FormatException('Malformed release key file.');
    }
    if (!ed25519ValidPublicKey(raw)) {
      throw const FormatException('Malformed release key file.');
    }
    return ReleaseKey(raw);
  }

  bool verify(ReleaseManifest manifest) {
    final signature = manifest.signature;
    if (signature == null || manifest.keyId != id) return false;
    final List<int> bytes;
    try {
      bytes = base64.decode(signature);
    } on FormatException {
      return false;
    }
    return ed25519Verify(raw, manifest.signedMessage, bytes);
  }
}

/// Why a desktop [manifest] must not be downloaded or installed over the
/// installed [installedCode] of [target]; null when its signature verifies
/// against the built-in [key] and it is a newer release for this platform
/// (spec #37 rule 1). Size and SHA-256 are checked while downloading.
String? desktopRefusal(
  ReleaseManifest manifest,
  ReleaseKey? key,
  int installedCode,
  String target,
) {
  if (key == null) return 'This build has no release key.';
  if (manifest.target != target) return 'The update is for another platform.';
  if (manifest.keyId != key.id) {
    return 'The update is signed with a different key than this app trusts.';
  }
  if (!key.verify(manifest)) return "The update's signature does not verify.";
  if (manifest.versionCode <= installedCode) {
    return 'The update (${manifest.versionCode}) is not newer than this '
        'version ($installedCode).';
  }
  return null;
}

/// Why the downloaded Android [archive] must not be installed over
/// [installed], given the [manifest] it was announced with; null when every
/// check passes (spec #28 A7, decision #108: the APK signer is the trust,
/// not the household release key). Size and SHA-256 are checked while
/// downloading. The archive's signing certificate must equal the installed
/// app's and the manifest's `signer_sha256`, and its `versionCode` must be
/// greater than the installed one and equal to the announced one.
String? androidRefusal(
  ReleaseManifest manifest,
  PackageFacts installed,
  PackageFacts? archive,
) {
  if (archive == null) {
    return 'The download is not a readable Android package.';
  }
  if (archive.packageName != installed.packageName) {
    return 'The download is a different app, not an update of AnJ Cloud.';
  }
  if (archive.signers.isEmpty) {
    return 'The download is not signed.';
  }
  if (!_sameSet(archive.signers, installed.signers)) {
    return 'The download is signed with a different key than this app.';
  }
  if (archive.signers.length != 1 ||
      archive.signers.single != manifest.signerSha256) {
    return "The download's signing key does not match the server's update record.";
  }
  if (archive.versionCode <= installed.versionCode) {
    return 'The download is version ${archive.versionName} '
        '(${archive.versionCode}), not newer than the installed '
        '${installed.versionName} (${installed.versionCode}).';
  }
  if (archive.versionCode != manifest.versionCode) {
    return "The download's version differs from the server's update record.";
  }
  return null;
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// A downloaded package failed a check. The file is discarded and [message]
/// says why.
class ReleaseRefused implements Exception {
  const ReleaseRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The user (or the controller's own deadline) stopped a download; the
/// partial file is removed and nothing else changes.
class ReleaseCancelled implements Exception {
  const ReleaseCancelled();
  @override
  String toString() => 'The download was cancelled.';
}
