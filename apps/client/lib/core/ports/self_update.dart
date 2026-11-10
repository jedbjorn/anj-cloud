/// Port: a desktop app's in-app update through its installed manager
/// (spec #37 U-linux; U-macos and U-windows implement the same port with
/// their managers).
///
/// Linux: `ManagerSelfUpdate` (lib/platform/linux/manager_self_update.dart)
/// reads the running bundle's receipt and runs the installed manager's
/// `apply-update` (tool/linux_install.py), which verifies the download again
/// against the release key built into the installed release, waits for this
/// process to exit, installs it and relaunches the app. macOS:
/// `MacosManagerSelfUpdate`; Windows: `WindowsManagerSelfUpdate`
/// (anj-cloud-manager.exe `apply-update`).
library;

import 'dart:io';

/// The running build, from its own release receipt.
class InstalledBuild {
  const InstalledBuild({
    required this.target,
    required this.version,
    required this.versionCode,
  });

  /// The update feed target (`linux-x86_64`, …).
  final String target;
  final String version;
  final int versionCode;
}

abstract interface class SelfUpdatePort {
  /// This build; null when it cannot update itself (a development build
  /// without a release receipt).
  Future<InstalledBuild?> installed();

  /// Makes the staging [directory] (inside the private profile) private to
  /// this user, as the manager requires.
  Future<void> prepare(Directory directory);

  /// Asks the installed manager to verify the downloaded [archive] against
  /// its [manifest] file without changing anything. Throws
  /// [SelfUpdateFailure] with the manager's reason.
  Future<void> check(File archive, File manifest);

  /// Hands the update to the installed manager, detached: it waits for this
  /// process to exit, installs, writes its outcome to [result] and starts
  /// the app again. Returns once the manager has started; the caller then
  /// quits the app.
  Future<void> handOver(File archive, File manifest, File result);
}

class SelfUpdateFailure implements Exception {
  const SelfUpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
