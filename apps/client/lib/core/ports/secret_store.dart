/// Port: keyring / secret storage for the device key and invitation
/// (decision #74). Linux: `KeyringSecrets`
/// (lib/platform/linux/keyring_secrets.dart), flutter_secure_storage over
/// libsecret. macOS: `KeychainSecrets` (lib/platform/macos/), the legacy
/// login keychain through the runner (spec #31 M3). Windows: `DpapiSecrets`.
library;

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// A secret store that can be wiped without its normal calls (spec #28 A3,
/// PR #60 review F5): when the store itself cannot start, every read, write
/// and delete fails, so recovery needs a route around it. Android's adapter
/// deletes the stored values and their Keystore wrapping key natively and
/// restarts the app. Implemented only where such a route exists.
abstract interface class SecretStoreReset {
  /// Deletes every stored secret and the key protecting them. The device's
  /// key is gone afterwards: it pairs again with a new key. May restart the
  /// process (Android), so callers persist their own state first.
  Future<void> resetAll();
}

/// A store that can add an item only where none exists. [DeviceIdentity]
/// stores a new device key through it, so a read that wrongly reported "no
/// key" can never lead to the real key being overwritten (spec #31 M3,
/// PR #72 review). macOS: [add] of an existing item throws
/// [SecretStoreUnavailable]. Stores without it (Linux, Windows) keep
/// [SecretStore.write].
abstract interface class AddOnlySecretStore implements SecretStore {
  /// Stores [value] under [key]; refuses, changing nothing, when an item
  /// already exists there.
  Future<void> add(String key, String value);
}

/// The platform's secret store cannot be used right now: on macOS the login
/// keychain is locked, access to the item was denied, or this process is
/// not in the user's GUI session (spec #31 "Secrets and Identity"). Nothing
/// was read or changed, and a later retry may succeed. A missing item is
/// not this: [SecretStore.read] returns null for it.
///
/// [message] is shown to the user; [code] is a diagnostic (an OSStatus on
/// macOS), never a secret.
class SecretStoreUnavailable implements Exception {
  const SecretStoreUnavailable(this.message, {this.code});
  final String message;
  final int? code;

  @override
  String toString() =>
      'SecretStoreUnavailable: $message${code == null ? '' : ' (status $code)'}';
}
