/// The set of platform adapters the shared code asks for (decision #74).
///
/// `platformAdapters()` (lib/platform/adapters.dart) returns the running
/// platform's set: Linux, macOS (spec #31) or Windows (spec #32).
library;

import 'autostart.dart';
import 'change_watcher.dart';
import 'desktop_launcher.dart';
import 'desktop_session.dart';
import 'documents.dart';
import 'root_filesystem.dart';
import 'root_placement.dart';
import 'root_location.dart';
import 'secret_store.dart';
import 'self_update.dart';

/// It is also the platform's [ChangeWatcherFactory]: `changeWatcher` starts
/// the local change watcher and `watchReportsChanges` says where a watch
/// can be trusted.
abstract interface class PlatformAdapters implements ChangeWatcherFactory {
  /// Native filesystem access; [library] overrides where the platform's
  /// native library is loaded from (tests, benchmarks).
  RootFilesystem rootFilesystem([String? library]);

  SecretStore secretStore();

  DesktopLauncher desktopLauncher({String? nativeLibrary});

  DesktopSession desktopSession();

  /// Start at login through the installed manager's [command].
  AutostartControl managerAutostart(String command);

  /// In-app update through the installed manager's [command] (spec #37);
  /// null where the platform's updater has not landed yet (macOS: U-macos
  /// with M6, Windows: U-windows with W5).
  SelfUpdatePort? managerSelfUpdate(String command);

  /// Where a new profile's synced folder and desktop shortcut go (spec #34
  /// P1, P2); [reservedParent] is the root the installer reserved for this
  /// profile, if any.
  RootPlacement rootPlacement({String? reservedParent});

  /// Where the sync root may be (spec #31 M3: macOS refuses protected,
  /// provider, snapshot and non-APFS locations; elsewhere any).
  RootLocationPolicy rootLocationPolicy();

  /// The device label sent with a pairing request, before the shared
  /// clipping (Linux and Windows: the host name; macOS: the Computer Name).
  Future<String> deviceLabel();

  /// Starts the platform's documents provider bridge for the running client
  /// and returns its "Apps with access" allowlist (spec #28 A5, decision
  /// #127), or null where the platform has no documents provider (Linux,
  /// macOS, Windows).
  AppAccess? startDocuments(DocumentsHost host, String profile);
}
