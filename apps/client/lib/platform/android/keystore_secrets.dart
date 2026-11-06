import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/ports/secret_store.dart';

/// Android [SecretStore] (spec #28 Device Identity, #108 Q5):
/// flutter_secure_storage 11.2.0 encrypts each value with AES-GCM under a
/// key that only this app's Android Keystore entry (non-exportable, bound to
/// the app's UID) can unwrap. Its default key cipher is used on purpose: the
/// Keystore-AES variant requires user authentication whenever the phone has
/// a screen lock, which background sync cannot give.
///
/// resetOnError is off: an unreadable store surfaces as an error (the device
/// pairs again knowingly) instead of being silently wiped. The knowing reset
/// is [resetAll]: the runner (DeviceChannel.kt) deletes the plugin's stored
/// values and its Keystore key without the plugin, which may be the part
/// that cannot start (PR #60 review F5), then restarts the app.
class KeystoreSecrets implements SecretStore, SecretStoreReset {
  static const _device = MethodChannel('cloud.anj/device');
  final FlutterSecureStorage storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
  @override
  Future<void> resetAll() => _device.invokeMethod<void>('resetSecrets');
}
