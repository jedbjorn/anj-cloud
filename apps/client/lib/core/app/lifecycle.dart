import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ports/desktop_session.dart';

/// Where a desktop keeps the app's icon: the menu bar on macOS (spec #31),
/// the system tray elsewhere. [defaultTargetPlatform] so widget tests can
/// override it.
String get desktopTrayName =>
    defaultTargetPlatform == TargetPlatform.macOS ? 'menu bar' : 'system tray';

/// One-time notices remembered in the profile (never in the sync root).
class LifecycleNotices {
  LifecycleNotices(Directory profile)
    : _file = File('${profile.path}/lifecycle-notices.json');
  final File _file;
  Map<String, bool> _values = {};

  bool operator [](String key) => _values[key] ?? false;

  void load() {
    try {
      if (!_file.existsSync()) return;
      final value = jsonDecode(_file.readAsStringSync());
      if (value is Map<String, dynamic>) {
        _values = {
          for (final entry in value.entries)
            if (entry.value is bool) entry.key: entry.value as bool,
        };
      }
    } on Object {
      _values = {};
    }
  }

  void mark(String key) {
    final updated = {..._values, key: true};
    try {
      final temporary = File('${_file.path}.tmp');
      temporary.writeAsStringSync(jsonEncode(updated), flush: true);
      temporary.renameSync(_file.path);
    } on FileSystemException {
      // A notice may then repeat; nothing else depends on it.
    }
    _values = updated;
  }
}

/// Close, hide, reopen and quit (decision #40, spec #16 lifecycle rules).
///
/// - Close with a tray host hides the window; sync continues.
/// - Close without a host quits cleanly after a notice that sync stops
///   (shown until the user has confirmed it once).
/// - A host lost while hidden shows the window again: never an invisible
///   process without a tray.
/// - Quit stops the worker at a checkpoint, then exits.
/// - Background start waits (bounded) for a tray host and otherwise starts
///   visible with a note.
class DesktopLifecycle extends ChangeNotifier {
  DesktopLifecycle({
    required this.window,
    required this.stopSync,
    this.tray,
    this.onShown,
    this.notices,
    this.background = false,
    this.trayWait = const Duration(seconds: 30),
  }) : visible = !background;

  final WindowControl window;
  final TrayControl? tray;

  /// Cooperative worker stop; returns whether it was clean.
  final Future<bool> Function() stopSync;
  final void Function()? onShown;
  final LifecycleNotices? notices;
  final bool background;
  final Duration trayWait;

  bool visible;
  bool quitting = false;

  /// Status note shown in the window (no tray found, tray lost).
  String? note;

  /// Set by the UI: explains that closing stops sync. True quits.
  Future<bool> Function()? confirmQuitWithoutTray;

  static const closeNotice = 'closeWithoutTray';
  StreamSubscription<bool>? _hosts;
  Future<bool>? _confirming;

  bool get hasTray => tray?.hostAvailable ?? false;

  Future<void> start() async {
    _hosts = tray?.hostChanges.listen(_hostChanged);
    if (!background) {
      onShown?.call();
      return;
    }
    if (await _waitForHost() || quitting) return;
    note =
        'No $desktopTrayName was found, so AnJ Cloud is shown in this window. '
        'Closing it stops sync.';
    await _show();
  }

  Future<bool> _waitForHost() async {
    final current = tray;
    if (current == null) return false;
    if (current.hostAvailable) return true;
    try {
      return await current.hostChanges
          .firstWhere((available) => available)
          .timeout(trayWait);
    } on TimeoutException {
      return current.hostAvailable;
    } on StateError {
      return false;
    }
  }

  void _hostChanged(bool available) {
    if (quitting) return;
    if (available) {
      if (note != null) {
        note = null;
        notifyListeners();
      }
      return;
    }
    if (!visible) {
      note =
          'The $desktopTrayName is no longer available, so AnJ Cloud was shown '
          'again. Closing this window now stops sync.';
      unawaited(_show());
    } else {
      notifyListeners();
    }
  }

  /// The window manager asked to close the window. Never closes directly.
  Future<void> closeRequested() async {
    if (quitting) return;
    if (hasTray) {
      await _hide();
      return;
    }
    if (!(notices?[closeNotice] ?? false)) {
      final confirm = confirmQuitWithoutTray;
      if (confirm != null) {
        // A second Close while the notice is open shares it (no stacking).
        final pending = _confirming ??= confirm();
        final bool quit;
        try {
          quit = await pending;
        } finally {
          if (identical(_confirming, pending)) _confirming = null;
        }
        if (!quit) return;
      }
      notices?.mark(closeNotice);
    }
    await quit();
  }

  /// Tray Open, `Activate()` from a second launch, or the app menu.
  Future<void> open() async {
    if (quitting) return;
    await _show();
  }

  Future<void> _show() async {
    if (quitting) return;
    visible = true;
    notifyListeners();
    await window.show();
    onShown?.call();
  }

  Future<void> _hide() async {
    visible = false;
    notifyListeners();
    await window.hide();
  }

  /// Explicit Quit (tray, app menu, SIGTERM). Idempotent.
  Future<void> quit() async {
    if (quitting) return;
    quitting = true;
    notifyListeners();
    try {
      await stopSync();
    } finally {
      await _hosts?.cancel();
      try {
        await tray?.close();
      } catch (_) {
        // A tray that cannot close must not keep the process (or a Windows
        // session end waiting on exit) alive.
      }
      await window.exit();
    }
  }

  @override
  void dispose() {
    unawaited(_hosts?.cancel());
    super.dispose();
  }
}
