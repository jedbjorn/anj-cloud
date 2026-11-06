import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/ports/desktop_session.dart';
import '../../core/sync/sync_schedule.dart';

/// [TrayControl] over the runner's `cloud.anj/tray` channel, shared by the
/// Windows and macOS desktop sessions (spec #31 "Desktop session pieces",
/// spec #32 W3), with the Linux tray's menu: status, Open, Pause or Resume,
/// Quit.
///
/// - Windows: the notification-area icon the runner adds with
///   `Shell_NotifyIcon` (windows/runner/desktop_integration.cpp).
///   [hostAvailable] is whether the icon is in Explorer's notification area;
///   [hostChanges] reports Explorer restarts (`TaskbarCreated`), after which
///   the runner has added the icon again.
/// - macOS: an `NSStatusItem` with a template image and an `NSMenu`
///   (macos/Runner/DesktopIntegration.swift). The menu bar is always there,
///   so the host never changes once the item is added.
class ChannelTray implements TrayControl {
  ChannelTray({
    required this.onOpen,
    required this.onTogglePause,
    required this.onQuit,
    this.title = 'AnJ Cloud',
    BinaryMessenger? messenger,
  }) : channel = MethodChannel(
         'cloud.anj/tray',
         const StandardMethodCodec(),
         messenger,
       ) {
    channel.setMethodCallHandler(_handle);
  }

  final MethodChannel channel;
  final void Function() onOpen;
  final void Function() onTogglePause;
  final void Function() onQuit;
  final String title;
  final _hosts = StreamController<bool>.broadcast();
  bool _available = false;
  bool _closed = false;

  @override
  bool get hostAvailable => _available && !_closed;

  @override
  Stream<bool> get hostChanges => _hosts.stream;

  /// Adds the icon; whether Explorer took it (it may come later).
  Future<bool> start() async {
    _available =
        await channel.invokeMethod<bool>('start', {'tooltip': title}) ?? false;
    return _available;
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_closed) return null;
    switch (call.method) {
      case 'open':
        onOpen();
      case 'togglePause':
        onTogglePause();
      case 'quit':
        onQuit();
      case 'hostChanged':
        _available = call.arguments == true;
        _hosts.add(_available);
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  @override
  Future<void> setState(SyncStatus status, {required bool paused}) async {
    if (_closed) return;
    await channel.invokeMethod<void>('setState', {
      'status': '$title: ${status.label}',
      'paused': paused,
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await channel.invokeMethod<void>('close');
    await _hosts.close();
  }
}
