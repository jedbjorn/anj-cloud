/// Port: desktop launcher / open-in-folder (decision #74). Linux:
/// `PlatformDesktopLauncher` (lib/platform/linux/desktop_launcher.dart).
library;

/// Platform integration stays outside portable library presentation and sync.
abstract class DesktopLauncher {
  Future<bool> openFile(String path);

  /// Whether [openFile] hands a working copy out only as a documents
  /// provider document, whose every open the engine tracks (Android). Only
  /// such copies are cleared automatically when unchanged (decision #184);
  /// a copy handed out as a plain path (Linux, macOS, Windows) is kept.
  bool get handsOutThroughProvider => false;
  Future<bool> openDirectory(String root, String relative, String rootIdentity);
}
