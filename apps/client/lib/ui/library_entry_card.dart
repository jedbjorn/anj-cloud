import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../design/badge_palette.dart';
import 'layout.dart';
import 'library_view.dart';
import 'shortcuts.dart';

/// Left bar: something here needs action. Wins over [syncBarColor].
const attentionBarColor = Colors.amber;

/// Left bar: a file in this folder (at any depth) is syncing. Material
/// blue 600, the sibling of the amber bar: at least 3:1 against both light
/// and dark card surfaces.
const syncBarColor = Color(0xff1e88e5);

/// Shown in place of a file's icon while it syncs. Turns slowly while the
/// library is on screen; static under reduced motion or while tickers are
/// off (window hidden in the tray). Owns an animation controller only while
/// it is actually animating, so an idle or hidden library runs no ticker.
class SyncingIcon extends StatefulWidget {
  const SyncingIcon({super.key, this.size = 24});
  final double size;

  @override
  State<SyncingIcon> createState() => _SyncingIconState();
}

class _SyncingIconState extends State<SyncingIcon>
    with TickerProviderStateMixin {
  AnimationController? _turns;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (animate && _turns == null) {
      _turns = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1600),
      )..repeat();
    } else if (!animate && _turns != null) {
      _turns!.dispose();
      _turns = null;
    }
  }

  @override
  void dispose() {
    _turns?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.sync, color: syncBarColor, size: widget.size);
    final turns = _turns;
    return Semantics(
      label: 'Syncing',
      child: ExcludeSemantics(
        child: turns == null
            ? icon
            // Counter-clockwise: the arrows of Icons.sync point that way.
            : RotationTransition(turns: ReverseAnimation(turns), child: icon),
      ),
    );
  }
}

/// The **Shared** badge's tooltip for a folder this account shares out
/// ("Shared with Alice, Bob"; spec #34 P4, superseding doc #29's
/// "not a badge" indicator). Null when the folder is not shared out: no
/// badge means private.
String? sharedOutNote(Map<String, dynamic> entry) {
  if (entry['incomingShare'] is Map ||
      entry['sharedOut'] != true ||
      entry['inSharedFolder'] == true ||
      entry['inIncomingShare'] == true) {
    return null;
  }
  final names = (entry['sharedWith'] as List?)?.cast<String>() ?? const [];
  return names.isEmpty ? 'Shared' : 'Shared with ${names.join(', ')}';
}

/// The neutral indicator of an incoming share's top folder ("Shared by
/// Alice", spec #26); null otherwise.
String? sharedByNote(Map<String, dynamic> entry) {
  final incoming = entry['incomingShare'];
  return incoming is Map ? 'Shared by ${incoming['owner_display_name']}' : null;
}

/// The incoming share's secondary line: "Shared by Alice · View only".
String? incomingShareLine(Map<String, dynamic> entry) {
  final incoming = entry['incomingShare'];
  if (incoming is! Map) return null;
  return [
    'Shared by ${incoming['owner_display_name']}',
    if (incoming['permission'] == 'view') 'View only',
  ].join(' · ');
}

class LibraryEntryCard extends StatefulWidget {
  const LibraryEntryCard({
    super.key,
    required this.row,
    required this.collapsed,
    required this.showPath,
    required this.onToggle,
    required this.onOpen,
    required this.onColorChanged,
    this.color,
    this.finish,
    this.onRename,
    this.menu,
    this.selecting = false,
    this.revealed = false,
    this.flat = false,
    this.onShowInFolder,
    this.selected = false,
    this.onSelect,
    this.touchInput = false,
  });

  final LibraryRow row;
  final bool collapsed;
  final bool showPath;
  final VoidCallback? onToggle;
  final VoidCallback? onOpen;
  final ValueChanged<int?> onColorChanged;
  final int? color;
  final Widget? finish;

  /// Shown for an item whose name is not allowed on other devices
  /// (decision #120): opens the Rename dialog.
  final VoidCallback? onRename;
  final Widget? menu;
  final bool selecting;
  final bool revealed;
  final bool flat;
  final VoidCallback? onShowInFolder;
  final bool selected;
  final VoidCallback? onSelect;

  /// The platform's input is touch (Android): a tap opens and a long-press
  /// opens the icon colour menu, as double-click and right-click do with a
  /// mouse. From the platform, never the window size: a small desktop window
  /// keeps double-click (spec #28 Phone Layout, #70 review).
  final bool touchInput;

  @override
  State<LibraryEntryCard> createState() => _LibraryEntryCardState();
}

class _ChooseColorIntent extends Intent {
  const _ChooseColorIntent();
}

class _LibraryEntryCardState extends State<LibraryEntryCard> {
  bool _focused = false;
  final _contentKey = GlobalKey();
  static const _palette = {
    'Red': Color(0xffb3261e),
    'Orange': Color(0xffa34e00),
    'Green': Color(0xff28703a),
    'Teal': Color(0xff007c83),
    'Blue': Color(0xff225bb5),
    'Purple': Color(0xff7851a9),
  };

  Future<void> _chooseColor([Offset? position]) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final anchor = _contentKey.currentContext!.findRenderObject() as RenderBox;
    final point = position == null
        ? anchor.localToGlobal(Offset(0, anchor.size.height), ancestor: overlay)
        : overlay.globalToLocal(position);
    final selected = await showMenu<int>(
      context: context,
      semanticLabel: 'Icon colour on this device',
      position: RelativeRect.fromSize(point & Size.zero, overlay.size),
      items: [
        const PopupMenuItem<int>(
          enabled: false,
          child: Text('Icon colour · this device'),
        ),
        for (final choice in _palette.entries)
          CheckedPopupMenuItem<int>(
            value: choice.value.toARGB32(),
            checked: widget.color == choice.value.toARGB32(),
            child: Row(
              children: [
                Icon(Icons.circle, color: choice.value, size: 16),
                const SizedBox(width: 12),
                Text(choice.key),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(value: -1, child: Text('Reset colour')),
      ],
    );
    if (selected == null || !mounted) return;
    try {
      widget.onColorChanged(selected == -1 ? null : selected);
    } on FileSystemException {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save icon colour. Check profile permissions.',
          ),
        ),
      );
    }
  }

  /// The badge chip's width: its label at 12 px plus the chip's padding.
  static double _badgeWidth(
    BuildContext context,
    String label,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + 32;
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final entry = row.entry;
    final scheme = Theme.of(context).colorScheme;
    final summary = librarySummary(entry);
    final badge = rowBadge(entry);
    final badgeColors = BadgePalette.of(context)[badge.tone];
    // Size sets spacing only (48 dp rows, toggle density, the badge's line);
    // the gestures and their hint follow [touchInput].
    final touch = compactLayout(context);
    final tap = widget.touchInput;
    final kind = row.directory ? 'folder' : 'file';
    final content = Expanded(
      child: FocusableActionDetector(
        key: _contentKey,
        enabled: widget.onOpen != null,
        mouseCursor: widget.onOpen == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: AppShortcuts.row(const _ChooseColorIntent()),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpen?.call();
              return null;
            },
          ),
          _ChooseColorIntent: CallbackAction<_ChooseColorIntent>(
            onInvoke: (_) {
              _chooseColor();
              return null;
            },
          ),
        },
        child: Semantics(
          button: widget.onOpen != null,
          onTap: widget.onOpen,
          child: Tooltip(
            message: widget.onOpen == null
                ? 'Unsupported item'
                : tap
                ? '${row.shown}\nTap to open $kind · Long-press for icon colour'
                : '${row.shown}\nDouble-click to open $kind · Right-click for icon colour\nKeyboard: Enter to open · Shift+F10 for colour',
            child: InkWell(
              key: ValueKey('content:${row.path}'),
              canRequestFocus: false,
              onTap: tap ? widget.onOpen : null,
              onDoubleTap: tap ? null : widget.onOpen,
              onLongPress: tap && widget.onOpen != null ? _chooseColor : null,
              onSecondaryTapUp: widget.onOpen == null
                  ? null
                  : (details) => _chooseColor(details.globalPosition),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                decoration: BoxDecoration(
                  color: _focused ? scheme.secondaryContainer : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                // A 48 dp touch target on a phone, even for a one-line row.
                constraints: touch ? const BoxConstraints(minHeight: 48) : null,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    if (row.syncing)
                      SyncingIcon(key: ValueKey('syncing-icon:${row.path}'))
                    else
                      Semantics(
                        // The blue bar's meaning for screen readers; amber
                        // already says "Needs attention in this folder".
                        label:
                            row.directory && row.syncingWithin && !row.attention
                            ? 'Syncing inside this folder'
                            : null,
                        child: Icon(
                          key: ValueKey('entry-icon:${row.path}'),
                          entry['kind'] == 'unsupported'
                              ? Icons.block
                              : row.directory
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: widget.color == null
                              ? scheme.primary
                              : Color(widget.color!),
                          size: 24,
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  p.posix.basename(row.shown),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              if (sharedOutNote(entry) case final note?) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: note,
                                  child: Semantics(
                                    label: note,
                                    child: ExcludeSemantics(
                                      child: Container(
                                        key: ValueKey(
                                          'shared-badge:${row.path}',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: scheme.secondaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.people_outline,
                                              size: 14,
                                              color:
                                                  scheme.onSecondaryContainer,
                                            ),
                                            const SizedBox(width: 3),
                                            Text(
                                              'Shared',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color: scheme
                                                        .onSecondaryContainer,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              if (sharedByNote(entry) case final note?) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: note,
                                  child: Semantics(
                                    label: note,
                                    child: ExcludeSemantics(
                                      child: Icon(
                                        key: ValueKey(
                                          'shared-icon:${row.path}',
                                        ),
                                        Icons.people_outline,
                                        size: 16,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (incomingShareLine(entry) case final line?)
                            Text(
                              line,
                              key: ValueKey('shared-by:${row.path}'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (widget.showPath)
                            Text(
                              row.shown,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (row.date != null)
                            Text(
                              row.date!,
                              key: ValueKey('date:${row.path}'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (row.directory && row.attention)
                            const Text('Needs attention in this folder'),
                          if (summary.isNotEmpty)
                            Text(
                              summary,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final actions = [
      if (!widget.selecting && widget.onShowInFolder != null)
        TextButton.icon(
          key: ValueKey('show-in-folder:${row.path}'),
          onPressed: widget.onShowInFolder,
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('Show in folder'),
        ),
      if (!widget.selecting && widget.onRename != null)
        TextButton.icon(
          key: ValueKey('rename:${row.path}'),
          onPressed: widget.onRename,
          icon: const Icon(Icons.drive_file_rename_outline, size: 18),
          label: const Text('Rename'),
        ),
      if (!widget.selecting) ?widget.finish,
    ];
    final trailing = [
      if (entry['synthetic'] != true)
        Tooltip(
          message:
              '${entry['effectiveRetention'] == 'cloud' ? 'Cloud-only' : 'Local and cloud'} · on this device${row.contextOnly ? '\nParent context for matching items' : ''}',
          child: Chip(
            key: ValueKey('badge:${row.path}'),
            label: Text(badge.label),
            labelStyle: TextStyle(color: badgeColors.foreground, fontSize: 12),
            // No background: the row surface shows through (plain tone).
            backgroundColor: badgeColors.background ?? Colors.transparent,
            side: badgeColors.border == null
                ? BorderSide.none
                : BorderSide(color: badgeColors.border!),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
        ),
      if (!widget.selecting) ?widget.menu,
    ];
    final controls = [...actions, ...trailing];
    final card = Card(
      key: ValueKey('card:${row.path}'),
      elevation: 0,
      color: widget.selected || widget.revealed
          ? scheme.secondaryContainer
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color:
              widget.selected ||
                  widget.revealed ||
                  (widget.selecting && _focused)
              ? scheme.primary
              : scheme.outlineVariant,
          width: widget.selected || widget.revealed ? 2 : 1,
        ),
      ),
      margin: EdgeInsets.only(
        left: 16 + (widget.flat ? 0 : 16.0 * row.depth.clamp(0, 6)),
        right: 16,
        top: 3,
        bottom: 3,
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        key: ValueKey('attention:${row.path}'),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 3,
              // Same predicate for files and folders: a file that needs
              // attention is itself marked, so an amber folder always leads
              // to a visibly amber row beneath it. A folder holding a syncing
              // file is blue unless it also needs attention: action outranks
              // information. The syncing file itself shows SyncingIcon.
              color: row.attention
                  ? attentionBarColor
                  : row.directory && row.syncingWithin
                  ? syncBarColor
                  : Colors.transparent,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 560;
            // A phone keeps the badge and the ⋮ menu on the name's line, as
            // on the desktop, while the name keeps room (a deep row or a
            // large font moves them below); labelled actions wrap below.
            final scaler = MediaQuery.textScalerOf(context);
            final room =
                constraints.maxWidth -
                (row.directory || widget.selecting ? 48 : 0) -
                (widget.menu != null && !widget.selecting ? 48 : 0) -
                (entry['synthetic'] == true
                    ? 0
                    : _badgeWidth(context, badge.label, scaler));
            final split = touch && narrow && room >= scaler.scale(120);
            final inline = !narrow
                ? controls
                : split
                ? trailing
                : const <Widget>[];
            final below = !narrow
                ? const <Widget>[]
                : split
                ? actions
                : controls;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (widget.selecting)
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          widget.selected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                        ),
                      )
                    else if (row.directory)
                      IconButton(
                        key: ValueKey('toggle:${row.path}'),
                        tooltip: widget.onToggle == null
                            ? 'Clear filters to collapse ${row.shown}'
                            : '${widget.collapsed ? 'Expand' : 'Collapse'} ${row.shown}',
                        onPressed: widget.onToggle,
                        // The theme's density on a phone keeps 48 dp.
                        visualDensity: touch ? null : VisualDensity.compact,
                        icon: Icon(
                          widget.collapsed
                              ? Icons.chevron_right
                              : Icons.expand_more,
                        ),
                      ),
                    content,
                    ...inline,
                  ],
                ),
                if (below.isNotEmpty)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: below,
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (!widget.selecting) return card;
    return Semantics(
      label: row.shown,
      selected: widget.selected,
      enabled: widget.onSelect != null,
      button: true,
      onTap: widget.onSelect,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        mouseCursor: widget.onSelect == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        shortcuts: {
          for (final key in AppShortcuts.activate) key: const ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          key: ValueKey('select-card:${row.path}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: ExcludeFocus(
            child: IgnorePointer(child: ExcludeSemantics(child: card)),
          ),
        ),
      ),
    );
  }
}
