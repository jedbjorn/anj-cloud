import 'dart:io';

import '../../core/ports/phone_folders.dart';
import '../../core/ports/autostart.dart';
import '../../core/ports/change_watcher.dart';
import '../../core/ports/desktop_launcher.dart';
import '../../core/ports/desktop_session.dart';
import '../../core/ports/documents.dart';
import '../../core/ports/platform_adapters.dart';
import '../../core/ports/root_filesystem.dart';
import '../../core/ports/root_location.dart';
import '../../core/ports/root_placement.dart';
import '../../core/ports/secret_store.dart';
import '../../core/ports/self_update.dart';
import 'android_change_watchers.dart';
import 'android_documents.dart';
import 'android_root_fs.dart';
import 'android_session.dart';
import 'background.dart';
import 'keystore_secrets.dart';

/// Android adapters (spec #28 A2, A5). The root filesystem, release guard
/// (with the provider's open-descriptor registry), watcher, secret store,
/// profile lock, the documents provider bridge and the launcher (Open and
/// Show in folder through the provider, R1) are real. [managerAutostart]
/// refuses rather than approximates (spec #3 portability rule): Android has
/// no installer manager. Start at login is the Background-sync switch (A4,
/// [AndroidBackgroundSwitch]): the runner's unique periodic WorkManager work,
/// which survives reboots. [command] is unused.
class AndroidPlatformAdapters implements PlatformAdapters {
  const AndroidPlatformAdapters();

  @override
  RootFilesystem rootFilesystem([String? library]) {
    // The sync worker maps the phone folders (spec #52); elsewhere the
    // plain app-private root.
    final phone = PhoneFolderLayout.active;
    return phone == null
        ? AndroidRootFs(library)
        : AndroidPhoneRootFs(phone, library);
  }

  @override
  SecretStore secretStore() => KeystoreSecrets();

  @override
  DesktopLauncher desktopLauncher({String? nativeLibrary}) => AndroidLauncher();

  @override
  DesktopSession desktopSession() => AndroidSession();

  /// The root is app-private storage the provider exposes (spec #28); no
  /// location rule beyond that (spec #31 M3's seam).
  @override
  RootLocationPolicy rootLocationPolicy() => const AnyRootLocation();

  /// The pairing label before the shared clip (spec #31 M3's seam): the
  /// host name, as on Linux, until Android's own device name (A3).
  @override
  Future<String> deviceLabel() async => Platform.localHostname;

  @override
  AutostartControl managerAutostart(String command) =>
      AndroidBackgroundSwitch();

  /// No desktop manager: Android updates through the system installer
  /// (spec #28 A7, its own updater), not a manager command.
  @override
  SelfUpdatePort? managerSelfUpdate(String command) => null;

  /// No automatic root through the placement: the Android entry
  /// (`mobile_main.dart`) configures its fixed root in app-private storage
  /// itself, as before spec #34 P1. No desktop shortcut; staging stays the
  /// private `.anj-cloud-<profileId>` sibling (P3 is Linux only).
  @override
  RootPlacement rootPlacement({String? reservedParent}) =>
      const PickerOnlyPlacement();

  @override
  AppAccess? startDocuments(DocumentsHost host, String profile) =>
      AndroidDocuments.start(host, profile);

  @override
  bool watchReportsChanges(RootFilesystem fs, int fd, String path) =>
      const AndroidChangeWatchers().watchReportsChanges(fs, fd, path);

  @override
  Future<ChangeWatcher?> changeWatcher(
    RootFilesystem fs,
    int rootFd,
    String rootPath,
    WatcherSettings settings, {
    Duration waitTimeout = const Duration(seconds: 30),
  }) => const AndroidChangeWatchers().changeWatcher(
    fs,
    rootFd,
    rootPath,
    settings,
    waitTimeout: waitTimeout,
  );
}
