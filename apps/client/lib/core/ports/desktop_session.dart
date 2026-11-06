/// Port: tray, window lifecycle and single instance (decision #74).
///
/// Linux: `LinuxDesktopSession` (lib/platform/linux/linux_desktop_session.dart)
/// with the profile lifetime lock (`ProfileLifetime`, native/posix/
/// lifecycle.inc), session-bus activation and a StatusNotifierItem tray
/// (`desktop_bus.dart`) and the GTK runner's window channel (`NativeWindow`).
library;

import 'dart:io';

import '../sync/sync_schedule.dart';

/// Native window operations (GTK runner channel), faked in tests.
abstract interface class WindowControl {
  Future<void> show();
  Future<void> hide();

  /// Ends the process. Called only after sync has stopped.
  Future<void> exit();
}

/// What the lifecycle needs from a tray, so it can be faked in tests.
abstract interface class TrayControl {
  /// A StatusNotifierWatcher exists and reports a registered host.
  bool get hostAvailable;
  Stream<bool> get hostChanges;
  Future<void> setState(SyncStatus status, {required bool paused});
  Future<void> close();
}

/// The profile lifetime lock, held for the life of the process.
/// The profile lifetime lock is held by another running process: the
/// platform's EWOULDBLOCK (11 on Linux, 35 on macOS), named `wouldBlock` by
/// the native boundary (spec #31 S2). [osError] keeps the platform number.
class ProfileInUseException extends FileSystemException {
  const ProfileInUseException(super.message, [super.path, super.osError]);
}

abstract interface class ProfileLock {
  /// The canonical profile directory the lock was taken on.
  Directory get profile;
}

/// Platform start-up services used by `main()`, in the order it calls them.
abstract interface class DesktopSession {
  /// The profile used without `--profile-dir`, given the platform's
  /// application support directory. Linux and macOS:
  /// `<support>/anj-cloud/default`. Windows: `%LOCALAPPDATA%\anj-cloud\profile`
  /// (spec #32, #134), moving an earlier Roaming default there once.
  String defaultProfile(String applicationSupport);

  /// Takes the profile lifetime lock before runApp, Manifest or keyring
  /// access. Throws a [FileSystemException] when the profile is unusable or
  /// already held (errno 11 when another process runs it).
  ProfileLock acquireProfile(String path, {int inherited = -1});

  /// Asks the instance already running [profile] to show its window.
  Future<bool> activateExisting(String? profile);

  /// Starts the tray; null when there is none (Close then quits).
  Future<TrayControl?> startTray({
    required void Function() onOpen,
    required void Function() onTogglePause,
    required void Function() onQuit,
  });

  WindowControl window();

  /// After [startTray] returned a tray: lets a later launch for [profile]
  /// show this window instead of starting a second process.
  Future<void> claimActivation(String profile, void Function() onActivate);
}
