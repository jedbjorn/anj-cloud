import '../../core/ports/autostart.dart';
import '../../core/ports/change_watcher.dart';
import '../../core/ports/desktop_launcher.dart';
import '../../core/ports/desktop_session.dart';
import '../../core/ports/documents.dart';
import '../../core/ports/platform_adapters.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/root_placement.dart';
import '../../core/ports/root_location.dart';
import '../../core/ports/secret_store.dart';
import '../../core/ports/self_update.dart';
import '../linux/desktop_launcher.dart';
import '../linux/manager_autostart.dart';
import 'keychain_secrets.dart';
import 'macos_change_watchers.dart';
import 'macos_root_fs.dart';
import 'macos_desktop_session.dart';
import 'macos_label.dart';
import 'macos_native_library.dart';
import 'macos_root_location.dart';
import 'macos_root_placement.dart';
import 'macos_self_update.dart';

/// macOS adapters (spec #31).
///
/// - Root filesystem, root identity and the busy-and-unchanged release
///   guard: the Darwin build of the shared native boundary (M1).
/// - Change watcher: [MacosChangeWatchers], one FSEvents stream on an APFS
///   root (M2); elsewhere, or when the stream fails, the per-pass stat scan.
/// - Secrets: [KeychainSecrets], the legacy login keychain (M3).
/// - Launcher: the shared launcher with folders enabled; url_launcher opens
///   files and folders through `NSWorkspace` after the root identity check
///   through the bundled dylib (M3).
/// - Desktop session: lock, menu-bar item, window, reopen, Quit (M3).
/// - Root location: [MacosRootLocation] (M3).
/// - Device label: the Computer Name (M3).
/// - Start at login: the install manager's `autostart` command (M6,
///   tool/macos/anj-cloud-macos-install.sh, embedded in the bundle), the
///   only writer of the LaunchAgent, as on Linux and Windows.
class MacosPlatformAdapters implements PlatformAdapters {
  const MacosPlatformAdapters();

  /// The shared POSIX binding over the bundle's libanj_rootfs.dylib
  /// ([library] only from tests and benchmarks; never from the environment).
  @override
  RootFilesystem rootFilesystem([String? library]) =>
      MacosRootFs(library ?? macosNativeLibraryPath());

  @override
  SecretStore secretStore() => KeychainSecrets();

  /// Open uses the default app for the file; a folder opens in Finder. Both
  /// are `NSWorkspace.open` (url_launcher_macos). The folder's root
  /// identity is checked through the bundle's dylib first, as on Linux.
  @override
  DesktopLauncher desktopLauncher({String? nativeLibrary}) =>
      PlatformDesktopLauncher(
        directorySupported: true,
        nativeLibrary: nativeLibrary ?? macosNativeLibraryPath(),
        errnoLabel: 'macOS errno',
      );

  @override
  DesktopSession desktopSession() => MacosDesktopSession();

  /// Spec #31 M8 (decision #164): ~/anj-cloud without a picker, the
  /// Desktop shortcut and staging inside the profile, as on Linux.
  @override
  RootPlacement rootPlacement({String? reservedParent}) =>
      MacosRootPlacement(reservedParent: reservedParent);

  /// The installed manager's `autostart` command: the copy embedded at
  /// `Contents/Resources/anj-cloud-macos-install.sh` (main.dart finds it).
  /// A bundle the manager did not install fails `status`, so the toggle
  /// stays hidden.
  @override
  AutostartControl managerAutostart(String command) =>
      ManagerAutostart(command);

  /// Spec #40 R2: the in-app update through the embedded manager's
  /// apply-update (a build without a release receipt offers none).
  @override
  SelfUpdatePort? managerSelfUpdate(String command) =>
      MacosManagerSelfUpdate(command);

  /// No documents provider: desktop apps open the root directly.
  @override
  AppAccess? startDocuments(DocumentsHost host, String profile) => null;

  @override
  RootLocationPolicy rootLocationPolicy() => MacosRootLocation();

  @override
  Future<String> deviceLabel() => macosDeviceLabel();

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      const MacosChangeWatchers().watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => const MacosChangeWatchers().changeWatcher(
    fs,
    rootFd,
    rootPath,
    settings,
    waitTimeout: waitTimeout,
  );
}

/// Decision #135: with the FSEvents watcher on an APFS root, ordinary passes
/// hash only reported paths and every file is verified at most this often
/// (the always-on desktop's bound; Android's is 15 minutes, #130 (3)).
const macosFullVerificationInterval = Duration(minutes: 60);
