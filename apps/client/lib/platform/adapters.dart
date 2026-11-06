import 'dart:io';

import '../core/app/controller.dart';
import '../core/ports/mobile_settings.dart';
import '../core/ports/platform_adapters.dart';
import 'android/android_platform_adapters.dart';
import 'android/background.dart';
import 'linux/linux_platform_adapters.dart';
import 'macos/macos_platform_adapters.dart';
import 'windows/windows_platform_adapters.dart';

/// The one place that picks platform implementations (decision #74).
PlatformAdapters platformAdapters() {
  if (Platform.isLinux) return const LinuxPlatformAdapters();
  if (Platform.isMacOS) return const MacosPlatformAdapters();
  if (Platform.isWindows) return const WindowsPlatformAdapters();
  if (Platform.isAndroid) return const AndroidPlatformAdapters();
  throw UnsupportedError(
    'AnJ Cloud has no platform adapters for ${Platform.operatingSystem} yet.',
  );
}

/// Background sync, network setting and notifications for [controller] on
/// a phone (Android, spec #28 A4); null on desktops.
MobileSettings? mobileSettings(ClientController controller) =>
    Platform.isAndroid ? AndroidBackground(controller) : null;
