import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The one desktop shortcut table (spec #31 M5, spec #32 W6). Linux and
/// Windows use Ctrl where macOS uses Cmd: [primary] resolves to `meta` on
/// macOS and `control` elsewhere. Keys without a modifier are the same on
/// every desktop. Shortcuts follow the platform, never the window size.
///
/// | Action | Linux, Windows | macOS |
/// |---|---|---|
/// | Search the library | Ctrl+F | Cmd+F |
/// | Leave Select mode, close a confirmation | Esc | Esc |
/// | Open the focused row | Enter or Space | Enter or Space |
/// | Icon colour of the focused row | Shift+F10 or the Menu key | Shift+F10 or the Menu key (where the keyboard has one) |
///
/// The window's own keys stay native: Alt+F4 on Windows and the window
/// manager's close on Linux hide the window to the tray (spec #16, W3).
class AppShortcuts {
  const AppShortcuts._();

  /// Whether the platform's command modifier is Cmd (macOS) rather than Ctrl.
  static bool get usesCommandKey =>
      defaultTargetPlatform == TargetPlatform.macOS;

  /// [key] with the platform's command modifier.
  static SingleActivator primary(LogicalKeyboardKey key) =>
      SingleActivator(key, control: !usesCommandKey, meta: usesCommandKey);

  /// The modifier as the platform writes it in hints.
  static String get primaryLabel => usesCommandKey ? 'Cmd' : 'Ctrl';

  static SingleActivator get search => primary(LogicalKeyboardKey.keyF);

  static const cancel = SingleActivator(LogicalKeyboardKey.escape);

  static const activate = [
    SingleActivator(LogicalKeyboardKey.enter),
    SingleActivator(LogicalKeyboardKey.space),
  ];

  static const rowMenu = [
    SingleActivator(LogicalKeyboardKey.f10, shift: true),
    SingleActivator(LogicalKeyboardKey.contextMenu),
  ];

  /// The row's keyboard map for a [FocusableActionDetector].
  static Map<ShortcutActivator, Intent> row(Intent menu) => {
    for (final key in activate) key: const ActivateIntent(),
    for (final key in rowMenu) key: menu,
  };
}
