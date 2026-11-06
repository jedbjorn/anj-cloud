import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/ports/secret_store.dart';

/// The keychain service every AnJ Cloud item uses: the bundle id, fixed
/// since M0 (tool/macos/mac_test_inventory.sh counts items under it).
const keychainService = 'cloud.anj.anj-cloud';

/// What the user sees while the login keychain cannot be used (spec #31,
/// the macOS form of Linux's "Unlock the keyring").
const keychainUnavailableMessage =
    'Keychain unavailable. AnJ Cloud keeps its device key in your login '
    'keychain, which is locked, was not allowed, or cannot be reached from '
    'this session. Nothing syncs until it is available: unlock it or allow '
    'access, then choose Retry.';

/// macOS [SecretStore] (spec #31 M3, decision #117 (3)): generic-password
/// items in the user's **legacy login keychain**, through the runner's
/// `cloud.anj/keychain` channel (macos/Runner/DesktopIntegration.swift),
/// which calls `SecItem` with `kSecUseDataProtectionKeychain` false and
/// restricts every query to the login keychain. The data-protection keychain
/// is never used (-34018 without a team).
///
/// This is the spec's Swift `SecItem` path rather than flutter_secure_storage
/// 11.2.0: that plugin reports a missing login keychain (a process outside
/// the GUI session) as a missing item, so the app could not tell "Keychain
/// unavailable" from "no key", and its read falls back across several
/// queries, each of which may raise the post-update password dialog.
///
/// Item attributes: service [keychainService], account = the shared key
/// name (`anj-cloud:<profile>:device-key`), label "AnJ Cloud". The
/// creating app is the item's trusted application (an ad-hoc build is
/// trusted by its cdhash, so after an update macOS asks once for the login
/// password, decision #118 Q1).
///
/// [write] adds or updates (the invitation); [add] only adds (a new device
/// key), so a misread "no key" can never overwrite a real one.
///
/// A read of a missing item returns null. Every other failure (no login
/// keychain in this session, locked with no UI allowed, access denied or
/// cancelled) throws [SecretStoreUnavailable] and changes nothing.
class KeychainSecrets implements AddOnlySecretStore {
  KeychainSecrets({
    BinaryMessenger? messenger,
    this.service = keychainService,
    this.interaction = true,
    @visibleForTesting this.testKeychain,
  }) : channel = MethodChannel(
         'cloud.anj/keychain',
         const StandardMethodCodec(),
         messenger,
       );

  final MethodChannel channel;
  final String service;

  /// False refuses any keychain dialog (the item stays unreadable instead):
  /// for checks that must not block on a prompt.
  final bool interaction;

  /// Test builds only: a keychain file used in place of the login keychain
  /// (the runner's ANJ_TEST_SEAMS; a shipped app refuses it).
  final String? testKeychain;

  Future<T?> _call<T>(String method, String key, [String? value]) async {
    try {
      return await channel.invokeMethod<T>(method, {
        'service': service,
        'account': key,
        'value': ?value,
        'interaction': interaction,
        'testKeychain': ?testKeychain,
      });
    } on PlatformException catch (error) {
      final details = error.details;
      throw SecretStoreUnavailable(
        keychainUnavailableMessage,
        code: details is int ? details : null,
      );
    } on MissingPluginException {
      throw const SecretStoreUnavailable(keychainUnavailableMessage);
    }
  }

  @override
  Future<String?> read(String key) => _call<String>('read', key);

  @override
  Future<void> write(String key, String value) =>
      _call<void>('write', key, value);

  /// Add-only (the device key): an existing item is refused by the runner
  /// (`errSecDuplicateItem`) and reported as unavailable, never replaced.
  @override
  Future<void> add(String key, String value) => _call<void>('add', key, value);

  @override
  Future<void> delete(String key) => _call<void>('delete', key);

  /// Whether an item exists, by its attributes only: never reads the
  /// secret, so never raises the access dialog (tests and diagnostics).
  Future<bool> exists(String key) async =>
      await _call<bool>('exists', key) ?? false;
}
