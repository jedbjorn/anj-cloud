import 'dart:io';

import 'package:flutter/services.dart';

/// The macOS device label for pairing (spec #31 Pairing, planner
/// proposal): the Computer Name from the runner's `cloud.anj/system`
/// channel (`SCDynamicStoreCopyComputerName`), for example "Sam's MacBook
/// Air"; when that is unavailable or blank, the host name without `.local`.
/// The shared `pairingLabel` clips it to what the gateway accepts.
Future<String> macosDeviceLabel({
  BinaryMessenger? messenger,
  String? hostname,
}) async {
  String? name;
  try {
    name = await MethodChannel(
      'cloud.anj/system',
      const StandardMethodCodec(),
      messenger,
    ).invokeMethod<String>('computerName');
  } catch (_) {
    // No runner channel (a headless run, a test without a binding, a
    // missing plugin or a platform error): the label is cosmetic, so fall
    // back to the host name rather than fail the pairing.
    name = null;
  }
  if (name != null && name.trim().isNotEmpty) return name.trim();
  return macosHostLabel(hostname ?? Platform.localHostname);
}

/// `Jeds-MacBook-Air.local` -> `Jeds-MacBook-Air`.
String macosHostLabel(String hostname) =>
    hostname.toLowerCase().endsWith('.local')
    ? hostname.substring(0, hostname.length - '.local'.length)
    : hostname;
