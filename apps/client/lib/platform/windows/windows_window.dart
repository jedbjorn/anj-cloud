import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/ports/desktop_session.dart';

/// Windows [WindowControl] over the runner's `cloud.anj/window` channel
/// (windows/runner/desktop_integration.cpp): show (restored and brought
/// forward), hide (Close to the tray, #40), and exit. The same channel
/// carries the runner's two events: `activate` (a second launch, through the
/// activation pipe) and `endSession` (logoff or shutdown).
class WindowsWindow implements WindowControl {
  WindowsWindow({
    this.fallback = const Duration(seconds: 5),
    this.sessionEndLimit = const Duration(seconds: 12),
    BinaryMessenger? messenger,
  }) : channel = MethodChannel(
         'cloud.anj/window',
         const StandardMethodCodec(),
         messenger,
       ) {
    channel.setMethodCallHandler(_handle);
  }

  final MethodChannel channel;
  final Duration fallback;

  /// How long session end may take before Windows is let go (the runner
  /// waits at most 15 s).
  final Duration sessionEndLimit;

  /// A later launch of this profile asked for the window.
  void Function()? onActivate;

  /// Logoff or shutdown: the explicit Quit path (stop sync, close the tray).
  /// Its final [exit] does not end the process: Windows does, after the
  /// runner's WM_ENDSESSION returns.
  void Function()? onSessionEnd;

  Completer<void>? _ending;

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'activate':
        onActivate?.call();
        return null;
      case 'endSession':
        final ending = _ending ??= Completer<void>();
        final quit = onSessionEnd;
        if (quit == null) return null;
        quit();
        try {
          await ending.future.timeout(sessionEndLimit);
        } on TimeoutException {
          stderr.writeln('anj-cloud: sync did not stop before session end');
        }
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
    final ending = _ending;
    if (ending != null) {
      // Session end: sync has stopped; the runner returns from WM_ENDSESSION
      // and Windows ends the process (closing the profile lock handle).
      if (!ending.isCompleted) ending.complete();
      return;
    }
    // As on Linux: sync has stopped; end the process if the embedder does not.
    Timer(fallback, () => exitProcess(0));
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  /// Asks the instance already running [profile] to show its window.
  Future<bool> activateExisting(String profile) async =>
      await channel.invokeMethod<bool>('activateExisting', {
        'profile': profile,
      }) ??
      false;

  /// Serves later launches of [profile] (the per-user activation pipe).
  Future<bool> claimActivation(String profile) async =>
      await channel.invokeMethod<bool>('claimActivation', {
        'profile': profile,
      }) ??
      false;
}

@visibleForTesting
void Function(int) exitProcess = exit;
