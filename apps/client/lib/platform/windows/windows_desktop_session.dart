import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ports/desktop_session.dart';
import 'profile_location.dart';
import 'windows_profile_lock.dart';
import '../desktop/channel_tray.dart';
import 'windows_window.dart';

/// Windows [DesktopSession] (spec #32 W3), the counterpart of
/// `LinuxDesktopSession`:
///
/// - the profile lifetime lock: a no-sharing lock file held for the process
///   ([WindowsProfileLock], anj_rootfs.dll);
/// - activation: a per-user named pipe (user SID plus a hash of the profile
///   path, a DACL for the user only, first instance only) served by the
///   runner; a second launch writes `activate` and exits;
/// - the notification-area icon ([ChannelTray]) and the window channel
///   ([WindowsWindow]): Close hides to the tray (#40), Quit stops sync and
///   exits;
/// - session end: the runner's WM_ENDSESSION runs the same Quit path (stop
///   sync, close the tray) before Windows ends the process.
///
/// The client refuses to run elevated: the runner checks before anything
/// starts (windows/runner/main.cpp).
class WindowsDesktopSession implements DesktopSession {
  WindowsDesktopSession({this.library});

  /// anj_rootfs.dll override (tests).
  final String? library;
  WindowsWindow? _window;
  ChannelTray? _tray;

  /// `%LOCALAPPDATA%\anj-cloud\profile` (spec #32 Locations, #134): nothing
  /// of the client's state roams. A profile at the earlier default (Roaming
  /// `<support>\anj-cloud\default`, builds before W5) is moved there once,
  /// while the new one is absent or unused (a manager install takes its
  /// lock before the client first runs); if the move fails (the old profile
  /// is in use), the old location keeps working this time.
  @override
  String defaultProfile(
    String applicationSupport, {
    Map<String, String>? environment,
  }) {
    final local = (environment ?? Platform.environment)['LOCALAPPDATA'];
    final legacy = p.join(applicationSupport, 'anj-cloud', 'default');
    if (local == null || local.isEmpty) return legacy;
    final adopted = adoptLegacyProfile(
      target: windowsProfile(local),
      legacy: legacy,
    );
    if (adopted.moved) {
      stderr.writeln('anj-cloud: moved the profile out of Roaming AppData');
    }
    if (adopted.note != null) stderr.writeln('anj-cloud: ${adopted.note}');
    return adopted.profile;
  }

  @override
  ProfileLock acquireProfile(String path, {int inherited = -1}) =>
      WindowsProfileLock.acquire(path, inherited: inherited, library: library);

  @override
  Future<bool> activateExisting(String? profile) async {
    if (profile == null) return false;
    try {
      return await (window() as WindowsWindow)
          .activateExisting(profile)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<TrayControl?> startTray({
    required void Function() onOpen,
    required void Function() onTogglePause,
    required void Function() onQuit,
  }) async {
    // Session end takes the Quit path whether or not a tray appears.
    (window() as WindowsWindow).onSessionEnd = onQuit;
    final tray = ChannelTray(
      onOpen: onOpen,
      onTogglePause: onTogglePause,
      onQuit: onQuit,
    );
    try {
      await tray.start().timeout(const Duration(seconds: 5));
    } catch (error) {
      // No runner channel: no tray, so Close quits (never an invisible
      // process).
      stderr.writeln('anj-cloud: tray unavailable: $error');
      return null;
    }
    // Explorer may not be up yet (a login start): the lifecycle waits for
    // the runner's TaskbarCreated report through hostChanges.
    _tray = tray;
    return tray;
  }

  @override
  WindowControl window() => _window ??= WindowsWindow();

  @override
  Future<void> claimActivation(
    String profile,
    void Function() onActivate,
  ) async {
    if (_tray == null) return;
    final window = this.window() as WindowsWindow;
    window.onActivate = onActivate;
    try {
      if (!await window
          .claimActivation(profile)
          .timeout(const Duration(seconds: 5))) {
        stderr.writeln('anj-cloud: activation pipe unavailable');
      }
    } catch (error) {
      stderr.writeln('anj-cloud: activation pipe unavailable: $error');
    }
  }
}
