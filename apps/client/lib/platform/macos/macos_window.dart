import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/ports/desktop_session.dart';

/// macOS [WindowControl] over the runner's `cloud.anj/window` channel
/// (macos/Runner/MainFlutterWindow.swift), spec #31 M3:
///
/// - `show` brings the window forward and restores the Dock icon; `hide`
///   orders it out and drops the Dock icon (the activation policy becomes
///   accessory), the macOS form of Linux's "closed to the tray";
/// - `exit` (after sync has stopped) lets AppKit terminate.
///
/// Runner events:
///
/// - `close`: the window's close button. As on Linux, where GTK's delete
///   event is Flutter's exit request, it goes to Flutter's exit-request
///   handlers (`main.dart`'s `AppLifecycleListener`), which hide to the
///   menu bar or, without one, quit after the shared notice.
/// - `quit`: AppKit's terminate request, from Cmd-Q and the app menu's
///   Quit, the Dock's Quit, a quit Apple event and logout. The runner waits
///   (`NSTerminateLater`) until [exit]; Dart answers true when it took the
///   request, false when nothing listens yet (AppKit then quits at once).
/// - `activate`: LaunchServices reopen (Dock, Finder, `open -a`) shows the
///   window.
class MacosWindow implements WindowControl {
  MacosWindow({
    this.fallback = const Duration(seconds: 5),
    BinaryMessenger? messenger,
    this.requestExit,
  }) : channel = MethodChannel(
         'cloud.anj/window',
         const StandardMethodCodec(),
         messenger,
       ) {
    channel.setMethodCallHandler(_handle);
  }

  final MethodChannel channel;
  final Duration fallback;

  /// Flutter's exit-request handlers (tests inject a stand-in).
  final Future<AppExitResponse> Function()? requestExit;

  /// The explicit Quit path (stop sync, close the menu-bar item, [exit]).
  void Function()? onQuit;

  /// A LaunchServices reopen asked for the window.
  void Function()? onActivate;

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'close':
        await (requestExit ?? ServicesBinding.instance.handleRequestAppExit)();
        return null;
      case 'quit':
        final quit = onQuit;
        if (quit == null) return false;
        quit();
        return true;
      case 'activate':
        onActivate?.call();
        return null;
    }
    throw MissingPluginException(call.method);
  }

  @override
  Future<void> show() => channel.invokeMethod<void>('show');

  @override
  Future<void> hide() => channel.invokeMethod<void>('hide');

  @override
  Future<void> exit() async {
    // Sync has already stopped; if AppKit does not end the process, exit
    // directly and let the kernel release the profile lock.
    Timer(fallback, () => exitProcess(0));
    await channel.invokeMethod<void>('exit');
  }
}

@visibleForTesting
void Function(int) exitProcess = exit;
