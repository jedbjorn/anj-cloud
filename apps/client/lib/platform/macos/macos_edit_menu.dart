import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The macOS Edit menu (spec #31 M5) over the runner's `cloud.anj/edit`
/// channel (macos/Runner/MainFlutterWindow.swift).
///
/// AppKit's own Cut, Copy, Paste and Select All act on its field editor,
/// whose text is not the text Flutter shows, so the runner sends each Edit
/// command here instead and it becomes the intent its keys raise in the
/// focused text field: Cut (Cmd-X), Copy (Cmd-C), Paste (Cmd-V), Select
/// All (Cmd-A), Undo (Cmd-Z) and Redo (Shift-Cmd-Z). A menu click and its
/// keys therefore always do the same thing.
///
/// Runner -> Dart: `perform` with the command name. Dart -> runner:
/// `focus`, whether a text field has keyboard focus; the runner enables the
/// Edit items only then.
class MacosEditMenu {
  MacosEditMenu({BinaryMessenger? messenger, FocusManager? focusManager})
    : channel = MethodChannel(
        'cloud.anj/edit',
        const StandardMethodCodec(),
        messenger,
      ),
      _focus = focusManager;

  final MethodChannel channel;
  final FocusManager? _focus;
  FocusManager get _manager => _focus ?? FocusManager.instance;
  bool? _reported;

  /// The intent of each Edit command, as the text field's keys raise it.
  static Intent? intentFor(String command) => switch (command) {
    'cut' => const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
    'copy' => CopySelectionTextIntent.copy,
    'paste' => const PasteTextIntent(SelectionChangedCause.keyboard),
    'selectAll' => const SelectAllTextIntent(SelectionChangedCause.keyboard),
    'undo' => const UndoTextIntent(SelectionChangedCause.keyboard),
    'redo' => const RedoTextIntent(SelectionChangedCause.keyboard),
    _ => null,
  };

  /// Whether the primary focus is a text field (an [EditableText]).
  bool get textFocused =>
      _manager.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  void start() {
    channel.setMethodCallHandler(_handle);
    _manager.addListener(_focusChanged);
    _focusChanged();
  }

  void stop() {
    _manager.removeListener(_focusChanged);
    channel.setMethodCallHandler(null);
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method != 'perform') throw MissingPluginException(call.method);
    final intent = intentFor('${call.arguments}');
    final context = _manager.primaryFocus?.context;
    if (intent == null || context == null || !textFocused) return false;
    Actions.maybeInvoke(context, intent);
    return true;
  }

  void _focusChanged() {
    final now = textFocused;
    if (now == _reported) return;
    _reported = now;
    channel.invokeMethod<void>('focus', now).catchError((Object _) {
      // No runner (tests, or before the engine attaches): nothing to enable.
    });
  }
}
