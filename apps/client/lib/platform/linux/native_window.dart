import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/ports/desktop_session.dart';

/// Linux [WindowControl]: the `cloud.anj/window` channel of the GTK runner
/// (linux/runner/my_application.cc).
class NativeWindow implements WindowControl {
  NativeWindow({this.fallback = const Duration(seconds: 5)});
  static const _channel = MethodChannel('cloud.anj/window');
  final Duration fallback;

  @override
  Future<void> show() => _channel.invokeMethod<void>('show');
  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');

  @override
  Future<void> exit() async {
    // If the embedder does not end the process, exit directly: sync has
    // already stopped and the kernel releases the profile locks.
    Timer(fallback, () => exitProcess(0));
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }
}

@visibleForTesting
void Function(int) exitProcess = exit;
