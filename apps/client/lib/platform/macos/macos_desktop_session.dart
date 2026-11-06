import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/ports/desktop_session.dart';
import '../desktop/channel_tray.dart';
import 'macos_edit_menu.dart';
import 'macos_profile_lock.dart';
import 'macos_window.dart';

/// macOS [DesktopSession] (spec #31 M3), the counterpart of
/// `LinuxDesktopSession` and `WindowsDesktopSession`:
///
/// - the profile lifetime lock: the same `flock` as Linux, in the Darwin
///   build of the native library ([MacosProfileLock]);
/// - single instance: LaunchServices keeps one instance per app, and a
///   reopen (Dock, Finder, `open -a`) reaches the running one as
///   `activate`; a second process started directly on a held profile exits
///   73 ([activateExisting] is false: there is no second-launch channel);
/// - the menu-bar item ([ChannelTray] over `cloud.anj/tray`, an
///   `NSStatusItem` with the Linux tray's menu) and the window channel
///   ([MacosWindow]): Close hides the window and its Dock icon (#40), and
///   every Quit (menu-bar item, Cmd-Q and the app menu, the Dock, logout)
///   stops sync before AppKit terminates;
/// - the main menu's Edit commands reach the focused text field
///   ([MacosEditMenu] over `cloud.anj/edit`, spec #31 M5);
/// - App Nap: the runner holds a user-initiated activity that still allows
///   idle system sleep, so the ~30 s idle pass timer is not stretched (#40).
class MacosDesktopSession implements DesktopSession {
  MacosDesktopSession({this.library});

  /// Overrides the bundled dylib (tests only).
  final String? library;
  MacosWindow? _window;
  ChannelTray? _tray;
  MacosEditMenu? _edit;
  static bool _debugRegistered = false;

  @override
  String defaultProfile(String applicationSupport) =>
      p.join(applicationSupport, 'anj-cloud', 'default');

  @override
  ProfileLock acquireProfile(String path, {int inherited = -1}) =>
      MacosProfileLock.acquire(path, inherited: inherited, library: library);

  /// A LaunchServices launch of a running app never starts a second
  /// process, so a second process here was started directly: it exits 73.
  @override
  Future<bool> activateExisting(String? profile) async => false;

  @override
  Future<TrayControl?> startTray({
    required void Function() onOpen,
    required void Function() onTogglePause,
    required void Function() onQuit,
  }) async {
    // AppKit's terminate requests take the Quit path whether or not the
    // menu-bar item appears.
    final window = this.window() as MacosWindow;
    window.onQuit = onQuit;
    // The Edit menu reaches the focused text field (spec #31 M5).
    _edit ??= MacosEditMenu()..start();
    if (kDebugMode) _registerDebugExtension(window);
    final tray = ChannelTray(
      onOpen: onOpen,
      onTogglePause: onTogglePause,
      onQuit: onQuit,
    );
    try {
      if (!await tray.start().timeout(const Duration(seconds: 5))) {
        throw StateError('the status item was not added');
      }
    } catch (error) {
      // No menu-bar item: Close quits (never an invisible process).
      stderr.writeln('anj-cloud: menu bar item unavailable: $error');
      return null;
    }
    _tray = tray;
    return tray;
  }

  @override
  WindowControl window() => _window ??= MacosWindow();

  @override
  Future<void> claimActivation(
    String profile,
    void Function() onActivate,
  ) async {
    if (_tray == null) return;
    (window() as MacosWindow).onActivate = onActivate;
  }

  /// Debug builds only: `ext.anj.desktop` drives the runner's own menu
  /// items, close button and state report (DesktopIntegration.swift, DEBUG
  /// only) from the VM service, for tool/macos/session_check.sh. Absent from
  /// release builds on both sides.
  static void _registerDebugExtension(MacosWindow window) {
    if (_debugRegistered) return;
    _debugRegistered = true;
    developer.registerExtension('ext.anj.desktop', (_, parameters) async {
      final reply = await window.channel.invokeMethod<Object?>(
        'debugPerform',
        parameters['action'],
      );
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'reply': reply}),
      );
    });
  }
}
