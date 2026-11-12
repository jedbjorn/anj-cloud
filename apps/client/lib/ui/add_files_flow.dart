import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app/add_files.dart';
import '../core/app/controller.dart';
import '../core/state/model.dart';

/// Why [entry] cannot receive added files now (spec #43 Eligible
/// Destinations), or null when it can. Not offered at all (null from
/// [addOffered]) on synthetic rows and files.
String? addDestinationProblem(
  Map<String, dynamic> entry, {
  required bool ready,
  required bool paused,
}) {
  if (paused) return 'Sync is paused';
  if (entry['viewOnly'] == true) return 'View-only share';
  if (!ready ||
      entry['localDirectoryAvailable'] != true ||
      entry['conflict'] != null) {
    return 'Not available on this device';
  }
  return null;
}

/// Whether a row's ⋮ menu holds Add files… and Add folder…: every real
/// folder row.
bool addOffered(Map<String, dynamic> entry) =>
    entry['kind'] == 'directory' &&
    entry['synthetic'] != true &&
    (entry['path'] as String? ?? '').isNotEmpty;

/// Add files… and Add folder… for a folder's ⋮ menu; disabled with the
/// reason when [reason] is set (as Manage sharing… shows its reason).
List<PopupMenuEntry<String>> addMenuItems(String path, String? reason) => [
  for (final (value, label) in const [
    ('addFiles', 'Add files…'),
    ('addFolder', 'Add folder…'),
  ])
    PopupMenuItem<String>(
      key: ValueKey('$value:$path'),
      value: value,
      enabled: reason == null,
      child: Tooltip(
        message: reason ?? 'Copy from this phone into this folder',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              semanticsLabel: reason == null
                  ? label
                  : '$label unavailable: $reason',
            ),
            if (reason != null)
              ExcludeSemantics(
                child: Text(
                  reason,
                  key: ValueKey('$value-reason:$path'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
];

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));

/// Folder ⋮ → Add files… / Add folder…: the system picker, then
/// [addSources].
Future<void> addFromPicker(
  BuildContext context,
  AddFiles adds,
  String destination, {
  required bool folder,
}) async {
  if (!adds.begin()) {
    _say(context, 'Another add is in progress');
    return;
  }
  try {
    List<AddSource>? sources;
    if (folder) {
      final name = await adds.port.pickFolder();
      if (name == null || !context.mounted) return;
      sources = await showDialog<List<AddSource>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ListingDialog(adds: adds, name: name),
      );
    } else {
      sources = await adds.port.pickFiles();
    }
    if (sources == null || sources.isEmpty || !context.mounted) return;
    await addSources(context, adds, destination, sources);
  } catch (error) {
    if (context.mounted) _say(context, 'Could not add: $error');
  } finally {
    adds.end();
  }
}

/// Before Copying, then the copy with progress, then the summary (spec #43).
/// The caller holds [AddFiles.begin]. Returns null when nothing was copied.
Future<AddResult?> addSources(
  BuildContext context,
  AddFiles adds,
  String destination,
  List<AddSource> sources,
) async {
  final AddPlan plan;
  try {
    plan = await adds.check(destination, sources);
  } on DocumentsFailure catch (error) {
    if (context.mounted) _say(context, 'Could not add: ${error.message}');
    return null;
  }
  if (!context.mounted) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AddConfirmDialog(plan: plan),
  );
  if (confirmed != true || !context.mounted) return null;
  final running = adds.run(plan);
  final result = await showDialog<AddResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AddProgressDialog(adds: adds, running: running),
  );
  if (result == null) {
    try {
      await running;
    } catch (error) {
      if (context.mounted) _say(context, 'Could not add: $error');
    }
    return null;
  }
  if (!context.mounted) return result;
  if (result.plain) {
    _say(context, result.headline);
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => AddSummaryDialog(result: result),
    );
  }
  return result;
}

class _ListingDialog extends StatefulWidget {
  const _ListingDialog({required this.adds, required this.name});
  final AddFiles adds;
  final String name;
  @override
  State<_ListingDialog> createState() => _ListingDialogState();
}

class _ListingDialogState extends State<_ListingDialog> {
  @override
  void initState() {
    super.initState();
    widget.adds.port.listFolder().then(
      (sources) {
        if (mounted) Navigator.pop(context, sources);
      },
      onError: (Object error) {
        if (!mounted) return;
        Navigator.pop(context);
        _say(context, 'Could not read the folder: $error');
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text('Reading ${widget.name}…'),
      content: const LinearProgressIndicator(
        semanticsLabel: 'Reading the folder',
      ),
      actions: [
        TextButton(
          key: const ValueKey('add-listing-cancel'),
          onPressed: widget.adds.cancel,
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// The one confirmation before anything is written.
class AddConfirmDialog extends StatelessWidget {
  const AddConfirmDialog({super.key, required this.plan});
  final AddPlan plan;

  @override
  Widget build(BuildContext context) {
    final skipped = plan.skipped;
    final blocked = plan.noSpace || plan.nothingToAdd;
    String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
    final what = [
      if (plan.folders > 0) count(plan.folders, 'folder'),
      if (plan.files > 0) count(plan.files, 'file'),
    ].join(' and ');
    final free = plan.free;
    return AlertDialog(
      title: Text('Add to ${plan.destination}'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (plan.noSpace) ...[
              Text(
                'Not enough space on this phone',
                key: const ValueKey('add-no-space'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Adding needs ${sizeLabel(plan.bytes)}. '
                '${free == null ? '' : '${sizeLabel(free < 0 ? 0 : free)} is free, and '}'
                '${sizeLabel(addFreeSpaceReserve)} is kept free for the phone.',
              ),
            ] else if (plan.nothingToAdd)
              const Text('Nothing can be added.', key: ValueKey('add-nothing'))
            else
              Text(
                '$what (${sizeLabel(plan.bytes)}) will be copied here. '
                'The originals stay where they are.',
                key: const ValueKey('add-summary'),
              ),
            if (skipped.isNotEmpty && !plan.noSpace) ...[
              const SizedBox(height: 16),
              Text(
                plan.nothingToAdd ? 'Skipped:' : 'These will be skipped:',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final item in skipped)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${item.name} — ${item.reason}'),
                ),
            ],
          ],
        ),
      ),
      actions: blocked
          ? [
              TextButton(
                key: const ValueKey('add-close'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Close'),
              ),
            ]
          : [
              TextButton(
                key: const ValueKey('add-cancel'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('add-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Add'),
              ),
            ],
    );
  }
}

class _AddProgressDialog extends StatefulWidget {
  const _AddProgressDialog({required this.adds, required this.running});
  final AddFiles adds;
  final Future<AddResult> running;
  @override
  State<_AddProgressDialog> createState() => _AddProgressDialogState();
}

class _AddProgressDialogState extends State<_AddProgressDialog> {
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    widget.running.then(
      (result) {
        if (mounted) Navigator.pop(context, result);
      },
      onError: (_) {
        if (mounted) Navigator.pop(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AnimatedBuilder(
      animation: widget.adds,
      builder: (context, _) {
        final progress = widget.adds.progress;
        final total = progress?.total ?? 0;
        final done = progress?.done ?? 0;
        final shown = total == 0 ? 0 : (done < total ? done + 1 : total);
        return AlertDialog(
          title: Text(
            'Adding $shown of $total to ${progress?.destination ?? ''}',
            key: const ValueKey('add-progress-title'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: total == 0 ? null : done / total,
                semanticsLabel: 'Adding files',
              ),
              const SizedBox(height: 8),
              if (progress != null && progress.totalBytes > 0)
                Text(
                  '${sizeLabel(progress.bytes)} of '
                  '${sizeLabel(progress.totalBytes)}',
                ),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('add-progress-cancel'),
              onPressed: _cancelling
                  ? null
                  : () {
                      setState(() => _cancelling = true);
                      widget.adds.cancel();
                    },
              child: Text(_cancelling ? 'Cancelling…' : 'Cancel'),
            ),
          ],
        );
      },
    ),
  );
}

/// What was added, added under another name, and skipped with reasons.
class AddSummaryDialog extends StatelessWidget {
  const AddSummaryDialog({super.key, required this.result});
  final AddResult result;

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(context).textTheme.titleSmall;
    return AlertDialog(
      title: Text(result.cancelled ? 'Add cancelled' : 'Add finished'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.headline, key: const ValueKey('add-result-headline')),
            if (result.renamed.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Added under a new name:', style: heading),
              for (final item in result.renamed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${item.name} — Added as ${item.addedAs}'),
                ),
            ],
            if (result.skipped.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Skipped:', style: heading),
              for (final item in result.skipped)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${item.name} — ${item.reason}'),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('add-result-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Opens "Save to AnJ Cloud" for every share that reaches the app (spec #43
/// Share Sheet), on top of whatever is shown, so the library keeps its
/// place.
class ShareReceiver extends StatefulWidget {
  const ShareReceiver({
    super.key,
    required this.adds,
    required this.controller,
    required this.child,
  });
  final AddFiles adds;
  final ClientController controller;
  final Widget child;
  @override
  State<ShareReceiver> createState() => _ShareReceiverState();
}

class _ShareReceiverState extends State<ShareReceiver> {
  StreamSubscription<void>? _arrivals;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _arrivals = widget.adds.port.shareArrived.listen((_) => _take());
    WidgetsBinding.instance.addPostFrameCallback((_) => _take());
  }

  @override
  void dispose() {
    _arrivals?.cancel();
    super.dispose();
  }

  Future<void> _take() async {
    if (_showing || !mounted) return;
    final SharedItems? share;
    try {
      share = await widget.adds.port.takeShare();
    } catch (_) {
      return;
    }
    if (share == null || !mounted) return;
    _showing = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SaveToCloudScreen(
            adds: widget.adds,
            controller: widget.controller,
            share: share!,
          ),
        ),
      );
    } finally {
      _showing = false;
    }
    // Another share arrived while this one was shown.
    unawaited(_take());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "Save to AnJ Cloud": the eligible folders as a list of paths; Save runs
/// the same check, copy and summary as Add files. Leaving it returns to the
/// app the share came from.
class SaveToCloudScreen extends StatefulWidget {
  const SaveToCloudScreen({
    super.key,
    required this.adds,
    required this.controller,
    required this.share,
  });
  final AddFiles adds;
  final ClientController controller;
  final SharedItems share;
  @override
  State<SaveToCloudScreen> createState() => _SaveToCloudScreenState();
}

class _SaveToCloudScreenState extends State<SaveToCloudScreen> {
  String? _folder;
  bool _saving = false;

  ClientController get controller => widget.controller;

  @override
  void dispose() {
    unawaited(widget.adds.port.leaveShare().catchError((_) {}));
    super.dispose();
  }

  /// Why nothing can be saved now, or null.
  String? get _problem {
    if (widget.share.items.isEmpty) {
      return 'Only files can be added to AnJ Cloud.';
    }
    if (controller.pairingState != 'paired') {
      return 'Pair this phone with AnJ Cloud first.';
    }
    if (controller.paused) {
      return 'Sync is paused. Resume sync, then share again.';
    }
    if (!controller.stateReceived) return null;
    if (!controller.canCreateFolder) {
      return 'AnJ Cloud is not ready on this phone yet. Try again in a moment.';
    }
    return null;
  }

  List<String> get _folders => [
    for (final entry in controller.entries)
      if (addOffered(entry) &&
          addDestinationProblem(
                entry,
                ready: controller.canCreateFolder,
                paused: controller.paused,
              ) ==
              null)
        entry['path'] as String,
  ]..sort();

  Future<void> _save() async {
    final folder = _folder;
    if (folder == null || _saving) return;
    if (!widget.adds.begin()) {
      _say(context, 'Another add is in progress');
      return;
    }
    setState(() => _saving = true);
    AddResult? result;
    try {
      result = await addSources(
        context,
        widget.adds,
        folder,
        widget.share.items,
      );
    } finally {
      widget.adds.end();
      if (mounted) setState(() => _saving = false);
    }
    if (result != null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final problem = _problem;
      final count = widget.share.items.length;
      final folders = problem == null ? _folders : const <String>[];
      if (_folder != null && !folders.contains(_folder)) _folder = null;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Save to AnJ Cloud'),
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: _saving ? null : () => Navigator.pop(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  problem ??
                      (!controller.stateReceived
                          ? 'Loading folders…'
                          : folders.isEmpty
                          ? 'No folder on this phone can take files right now.'
                          : 'Choose a folder for '
                                '${count == 1 ? '1 file' : '$count files'}.'),
                  key: const ValueKey('share-message'),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final folder in folders)
                      ListTile(
                        key: ValueKey('share-folder:$folder'),
                        leading: Icon(
                          _folder == folder
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(folder),
                        selected: _folder == folder,
                        onTap: _saving
                            ? null
                            : () => setState(() => _folder = folder),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey('share-cancel'),
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: Text(problem == null ? 'Cancel' : 'Close'),
                    ),
                    if (problem == null) ...[
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('share-save'),
                        onPressed: _folder == null || _saving ? null : _save,
                        child: const Text('Save'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
