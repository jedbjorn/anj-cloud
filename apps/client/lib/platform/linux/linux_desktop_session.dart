import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;

import '../../core/ports/desktop_session.dart';
import 'desktop_bus.dart';
import 'native_window.dart';
import 'profile_lifetime.dart';

/// Linux [DesktopSession]: the profile lifetime lock (flock in
/// native/posix/lifecycle.inc), a StatusNotifierItem tray and per-profile
/// activation on the session bus, and the GTK runner's window channel.
/// The tray and the activation service share one session-bus connection.
class LinuxDesktopSession implements DesktopSession {
  DBusClient? _bus;
  StatusNotifierTray? _tray;

  @override
  String defaultProfile(String applicationSupport) =>
      p.join(applicationSupport, 'anj-cloud', 'default');

  @override
  ProfileLock acquireProfile(String path, {int inherited = -1}) =>
      ProfileLifetime.acquire(path, inherited: inherited);

  @override
  Future<bool> activateExisting(String? profile) async {
    if (profile == null) return false;
    final bus = DBusClient.session();
    try {
      return await activateRunning(
        bus,
        profile,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      return false;
    } finally {
      await bus.close();
    }
  }

  @override
  Future<TrayControl?> startTray({
    required void Function() onOpen,
    required void Function() onTogglePause,
    required void Function() onQuit,
  }) async {
    StatusNotifierTray? tray;
    DBusClient? bus;
    try {
      bus = DBusClient.session();
      final icon = await rootBundle.load('assets/branding/harbor/icon-128.png');
      final created = StatusNotifierTray(
        bus,
        onOpen: onOpen,
        onTogglePause: onTogglePause,
        onQuit: onQuit,
        pixmaps: trayPixmaps(icon.buffer.asUint8List()),
      );
      await created.start().timeout(const Duration(seconds: 5));
      tray = created;
    } catch (error) {
      // No session bus: no tray, so Close quits (never an invisible process).
      stderr.writeln('anj-cloud: tray unavailable: $error');
    }
    _bus = bus;
    _tray = tray;
    return tray;
  }

  @override
  WindowControl window() => NativeWindow();

  @override
  Future<void> claimActivation(
    String profile,
    void Function() onActivate,
  ) async {
    final bus = _bus;
    if (bus != null && _tray != null) {
      try {
        await ActivationService.claim(
          bus,
          profile,
          onActivate,
        ).timeout(const Duration(seconds: 5));
      } catch (error) {
        stderr.writeln('anj-cloud: activation service unavailable: $error');
      }
    }
  }
}
