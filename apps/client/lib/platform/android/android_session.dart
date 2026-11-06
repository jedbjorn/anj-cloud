import 'package:path/path.dart' as p;

import '../../core/ports/desktop_session.dart';
import '../linux/profile_lifetime.dart';

/// Android [DesktopSession] (spec #28 What Android Is): the profile lock
/// (the same flock as Linux, in app-private storage) and nothing else. There
/// is no tray and no window lifecycle: leaving the app does not stop sync and
/// there is no Quit (Pause is the user's control, #40, #53). One process
/// runs one engine (SyncHost), so there is never another instance to
/// activate.
class AndroidSession implements DesktopSession {
  /// `<files>/anj-profile/default`, beside the root in app-private storage
  /// ([applicationSupport] is the app's files directory).
  @override
  String defaultProfile(String applicationSupport) =>
      p.join(applicationSupport, 'anj-profile', 'default');

  @override
  ProfileLock acquireProfile(String path, {int inherited = -1}) =>
      ProfileLifetime.acquire(path, inherited: inherited);

  @override
  Future<bool> activateExisting(String? profile) async => false;

  @override
  Future<TrayControl?> startTray({
    required void Function() onOpen,
    required void Function() onTogglePause,
    required void Function() onQuit,
  }) async => null;

  @override
  WindowControl window() => const AndroidWindow();

  @override
  Future<void> claimActivation(
    String profile,
    void Function() onActivate,
  ) async {}
}

/// The activity is the window; its controls do nothing.
class AndroidWindow implements WindowControl {
  const AndroidWindow();
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<void> exit() async {}
}
