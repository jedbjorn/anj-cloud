import 'package:flutter/services.dart';

import '../../core/ports/phone_folders.dart';

/// [PhoneFolderAccess] over the runner's `cloud.anj/phone_folders` channel
/// (`PhoneFoldersChannel.kt`, spec #52).
class AndroidPhoneFolders implements PhoneFolderAccess {
  const AndroidPhoneFolders();

  static const _channel = MethodChannel('cloud.anj/phone_folders');

  @override
  Future<PhoneFolderLayout> check() async {
    final state = Map<String, Object?>.from(
      await _channel.invokeMethod<Map>('state') ?? const {},
    );
    final base = state['base'] as String? ?? '/storage/emulated/0';
    final media = state['media'] as String? ?? '$base/Android/media';
    return PhoneFolderLayout(
      base: base,
      staging: '$media/anj-staging',
      paused: state['granted'] != true || state['mounted'] != true,
    );
  }

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  @override
  Future<void> scan(List<String> paths) =>
      _channel.invokeMethod<void>('scan', {'paths': paths});
}
