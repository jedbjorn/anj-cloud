/// Port: desktop launcher / open-in-folder (decision #74). Linux:
/// `PlatformDesktopLauncher` (lib/platform/linux/desktop_launcher.dart).
library;

/// Platform integration stays outside portable library presentation and sync.
abstract class DesktopLauncher {
  Future<bool> openFile(String path);
  Future<bool> openDirectory(String root, String relative, String rootIdentity);
}
