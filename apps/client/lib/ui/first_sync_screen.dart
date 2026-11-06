import 'dart:async';

import 'package:flutter/material.dart';

import '../core/sync/first_sync.dart';
import 'layout.dart';

/// Binary units, as the rest of the client (MiB).
String formatSize(int bytes) {
  const units = ['bytes', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return bytes == 1 ? '1 byte' : '$bytes bytes';
  return '${value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

/// The first-sync screen (decisions #118, #163): the standard onboarding
/// step at a device's first pairing on every client. Documents, Music and
/// Videos are always on the device; under each it lists their subfolders and
/// their loose files as one row, then any other top-level folder, with sizes
/// and the total. Ticked rows stay on this device (Local), the others are
/// Cloud-only, and each folder's choice can be changed later in the library.
/// Nothing downloads until the user confirms. [defaultChoice] is the
/// platform's: Android starts with nothing ticked, desktops with everything.
class FirstSyncScreen extends StatefulWidget {
  const FirstSyncScreen({
    super.key,
    required this.load,
    required this.defaultChoice,
    required this.onConfirm,
    this.onPair,
  });

  final Future<FirstSyncListing> Function() load;
  final FirstSyncDefault defaultChoice;
  final Future<void> Function(List<String> folders, Set<String> keepLocal)
  onConfirm;

  /// Opens pairing again (the device may have been revoked while the
  /// choice was pending); the listing reloads when it returns. The gate
  /// stays closed meanwhile: nothing syncs until the choice is confirmed.
  final Future<void> Function()? onPair;

  @override
  State<FirstSyncScreen> createState() => _FirstSyncScreenState();
}

class _FirstSyncScreenState extends State<FirstSyncScreen> {
  FirstSyncListing? _listing;
  final _keepLocal = <String>{};
  String? _error;
  bool _loading = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.load();
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _keepLocal
          ..clear()
          ..addAll(listing.defaultKeep(widget.defaultChoice));
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not list your folders. Check the connection, then try again. Nothing has been downloaded.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pairAgain() async {
    await widget.onPair!();
    if (mounted) await _load();
  }

  Future<void> _confirm() async {
    final listing = _listing!;
    setState(() => _confirming = true);
    try {
      await widget.onConfirm(listing.paths, {..._keepLocal});
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Your choice could not be saved. Nothing has been downloaded; try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final theme = Theme.of(context);
    final busy = _loading || _confirming;
    // A phone (spec #28 Phone Layout): the screen scrolls as one list, with
    // Start sync at the bottom while everything fits, so landscape or a
    // large font never squeezes the folders or the button out.
    final compact = compactLayout(context);
    final header = <Widget>[
      Text(
        'Choose what stays on this device',
        style: theme.textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Documents, Music and Videos are always on this device. Choose what inside them is kept here: ticked items download, the others stay in the cloud and download only when you open a file. "New and loose files" also decides folders added there later. You can change any of this later from the folder\'s menu. Nothing downloads until you start sync.',
      ),
      const SizedBox(height: 12),
      if (_error != null) ...[
        Text(
          _error!,
          key: const ValueKey('first-sync-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 8),
      ],
    ];
    Widget? folders;
    var tiles = const <Widget>[];
    if (listing == null) {
      folders = Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _load,
                    child: const Text('Try again'),
                  ),
                  if (widget.onPair != null)
                    FilledButton(
                      key: const ValueKey('first-sync-pair'),
                      onPressed: _pairAgain,
                      child: const Text('Pair this device again'),
                    ),
                ],
              ),
      );
    } else if (listing.choices.isEmpty) {
      folders = const Center(child: Text('Your cloud has no folders yet.'));
    } else {
      Widget row(FirstSyncChoice choice) => CheckboxListTile(
        key: ValueKey('first-sync:${choice.path}'),
        value: _keepLocal.contains(choice.path),
        onChanged: busy
            ? null
            : (value) => setState(() {
                value == true
                    ? _keepLocal.add(choice.path)
                    : _keepLocal.remove(choice.path);
              }),
        contentPadding: EdgeInsetsDirectional.only(
          start: choice.top == null ? 16 : 32,
          end: 16,
        ),
        secondary: Icon(
          choice.looseFiles
              ? Icons.description_outlined
              : Icons.folder_outlined,
        ),
        title: Text(choice.label, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (choice.files != null)
              choice.files == 1 ? '1 file' : '${choice.files} files',
            choice.size == null ? 'Size unknown' : formatSize(choice.size!),
          ].join(' · '),
        ),
      );
      tiles = [
        for (final top in listing.tops) ...[
          ListTile(
            key: ValueKey('first-sync-top:$top'),
            leading: const Icon(Icons.folder),
            title: Text(top, style: theme.textTheme.titleMedium),
            subtitle: const Text('Always on this device'),
          ),
          for (final choice in listing.choices)
            if (choice.top == top) row(choice),
        ],
        for (final choice in listing.choices)
          if (choice.top == null) row(choice),
      ];
      if (!compact) folders = ListView(children: tiles);
    }
    final footer = <Widget>[
      if (listing != null) ...[
        const Divider(),
        if (listing.rootFiles > 0)
          Text(
            '${listing.rootFiles == 1 ? '1 file' : '${listing.rootFiles} files'} at the top level: ${formatSize(listing.rootFilesSize)}',
          ),
        Text(
          'Total in the cloud: ${listing.sizesComplete ? '' : 'at least '}${formatSize(listing.total)}',
          key: const ValueKey('first-sync-total'),
        ),
        Text(
          'Downloads now: ${formatSize(listing.downloadSize(_keepLocal))}',
          key: const ValueKey('first-sync-download'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('first-sync-confirm'),
          onPressed: busy ? null : _confirm,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Start sync'),
        ),
      ],
      if (busy && listing != null) const LinearProgressIndicator(),
    ];
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: compact
                ? CustomScrollView(
                    slivers: [
                      SliverList.list(children: header),
                      if (folders == null)
                        SliverList.list(children: tiles)
                      else
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: folders,
                          ),
                        ),
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: footer,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...header,
                      Expanded(child: folders!),
                      ...footer,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
