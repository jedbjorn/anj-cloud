import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app/fetch_jobs.dart';
import '../core/gateway/fetch_api.dart';
import 'shortcuts.dart';

/// The Downloader tab (spec #42 F5): paste links, choose Audio or Video,
/// press Download; below, the account's jobs, newest first. All state and
/// every request live in [FetchJobs]; this widget only shows and calls it.
/// One scrollable holds the form and the list, so a phone in landscape or a
/// large font never squeezes either out.
class DownloaderTab extends StatefulWidget {
  const DownloaderTab({
    super.key,
    required this.jobs,
    required this.links,
    required this.onShowInFolder,
    this.touchInput = false,
  });

  final FetchJobs jobs;

  /// The pasted field, owned by the home screen so it survives a tab change.
  final TextEditingController links;

  /// The library's reveal for a placed file (its path in the account).
  final ValueChanged<String> onShowInFolder;

  /// Touch platforms (Android) also refresh by pulling the list down.
  final bool touchInput;

  @override
  State<DownloaderTab> createState() => _DownloaderTabState();
}

/// A job's state in plain words (spec #42 "Downloader tab").
String fetchStateLabel(FetchJob job) => switch (job.state) {
  FetchState.waiting => 'Waiting',
  FetchState.checking => 'Checking',
  FetchState.downloading =>
    job.percent == null
        ? 'Downloading'
        : 'Downloading ${job.percent!.floor()}%',
  FetchState.placing => 'Saving',
  // The height obtained: it may be lower than the one asked for.
  FetchState.done =>
    job.kind == FetchKind.video && job.height != null
        ? 'Done · ${job.height}p'
        : 'Done',
  FetchState.failed => "Couldn't download",
  FetchState.rejected => 'Not supported',
  FetchState.cancelled => 'Cancelled',
  // A state a newer server added.
  FetchState.unknown => job.isFinished ? 'Finished' : 'In progress',
};

/// What the field says about lines that were not links and stayed in it.
String ignoredLinesNote(int count) => count == 1
    ? '1 line is not a link and was left in the box.'
    : '$count lines are not links and were left in the box.';

class _DownloaderTabState extends State<DownloaderTab> {
  FetchJobs get jobs => widget.jobs;

  /// Under the field: a submit error (error style) or a note (plain).
  String? _error;
  String? _note;

  /// Rows with a Cancel or Remove under way.
  final _acting = <String>{};
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    widget.links.addListener(_edited);
  }

  @override
  void didUpdateWidget(DownloaderTab old) {
    super.didUpdateWidget(old);
    if (old.links != widget.links) {
      old.links.removeListener(_edited);
      widget.links.addListener(_edited);
    }
  }

  @override
  void dispose() {
    widget.links.removeListener(_edited);
    super.dispose();
  }

  String _text = '';

  /// Typing clears the last submit's message and re-evaluates the button.
  void _edited() {
    if (widget.links.text == _text) return;
    _text = widget.links.text;
    setState(() {
      _error = null;
      _note = null;
    });
  }

  bool get _canSubmit {
    if (jobs.submitting) return false;
    return switch (parseFetchLinks(widget.links.text)) {
      FetchLinksReady(:final links) => links.isNotEmpty,
      // Pressing Download says why nothing is sent.
      FetchLinksTooMany() => true,
    };
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final parsed = parseFetchLinks(widget.links.text);
    switch (parsed) {
      case FetchLinksTooMany():
        setState(() {
          _error = parsed.message;
          _note = null;
        });
      case FetchLinksReady(:final links, :final ignored):
        final error = await jobs.submit(links);
        if (!mounted) return;
        if (error == null) {
          // Sent: only the lines that were not links stay.
          _text = ignored.join('\n');
          widget.links.text = _text;
        }
        setState(() {
          _error = error?.message;
          _note = error == null && ignored.isNotEmpty
              ? ignoredLinesNote(ignored.length)
              : null;
        });
    }
  }

  void _say(FetchError? error) {
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message)));
  }

  Future<void> _act(
    String id,
    Future<FetchError?> Function(String) action,
  ) async {
    if (!_acting.add(id)) return;
    setState(() {});
    try {
      _say(await action(id));
    } finally {
      _acting.remove(id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _clear() async {
    if (_clearing) return;
    setState(() => _clearing = true);
    try {
      _say(await jobs.clearFinished());
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final field = CallbackShortcuts(
      bindings: {AppShortcuts.submit: () => unawaited(_submit())},
      child: TextField(
        key: const ValueKey('downloader-links'),
        controller: widget.links,
        minLines: 2,
        maxLines: 5,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          isDense: true,
          labelText: 'Paste one or more links',
          alignLabelWithHint: true,
          border: OutlineInputBorder(),
        ),
      ),
    );
    Widget chip<T>(
      String key,
      String label,
      T value,
      T current,
      void Function(T) set,
    ) => ChoiceChip(
      key: ValueKey('downloader-$key'),
      label: Text(label),
      selected: value == current,
      showCheckmark: false,
      onSelected: (_) => set(value),
    );
    final choices = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final kind in FetchKind.values)
          chip(kind.name, kind.label, kind, jobs.kind, jobs.setKind),
        if (jobs.kind == FetchKind.video) ...[
          const SizedBox(width: 6),
          for (final resolution in FetchResolution.values)
            chip(
              resolution.label,
              resolution.label,
              resolution,
              jobs.resolution,
              jobs.setResolution,
            ),
        ],
      ],
    );
    final destination = Text(
      'Saves to ${jobs.kind.folder}',
      key: const ValueKey('downloader-destination'),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
    final download = FilledButton.icon(
      key: const ValueKey('downloader-submit'),
      onPressed: _canSubmit ? _submit : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      icon: const Icon(Icons.download),
      label: const Text('Download'),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            field,
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  key: const ValueKey('downloader-error'),
                  style: TextStyle(color: scheme.error),
                ),
              ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_note!, key: const ValueKey('downloader-note')),
              ),
            const SizedBox(height: 8),
            // Phone: the choice, then where it goes beside the button.
            if (constraints.maxWidth < 560) ...[
              choices,
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: destination),
                  const SizedBox(width: 8),
                  download,
                ],
              ),
            ] else
              Row(
                children: [
                  // A large font moves the destination under the choice.
                  Expanded(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [choices, destination],
                    ),
                  ),
                  const SizedBox(width: 16),
                  download,
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Downloads',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        TextButton(
          key: const ValueKey('downloader-clear'),
          onPressed: jobs.hasFinished && !_clearing ? _clear : null,
          child: const Text('Clear finished'),
        ),
        IconButton(
          key: const ValueKey('downloader-refresh'),
          tooltip: 'Refresh',
          onPressed: () => unawaited(jobs.refresh()),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );

  Widget _row(BuildContext context, FetchJob job) {
    final busy = _acting.contains(job.id);
    return _JobCard(
      key: ValueKey('job:${job.id}'),
      job: job,
      actions: [
        if (!job.isFinished)
          _JobAction(
            'job-cancel:${job.id}',
            Icons.close,
            'Cancel',
            busy ? null : () => _act(job.id, jobs.cancel),
          ),
        if (job.state == FetchState.done && job.path != null)
          _JobAction(
            'job-show:${job.id}',
            Icons.folder_open,
            'Show in folder',
            () => widget.onShowInFolder(job.path!),
          ),
        if (job.isFinished)
          _JobAction(
            'job-remove:${job.id}',
            Icons.delete_outline,
            'Remove',
            busy ? null : () => _act(job.id, jobs.remove),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: jobs,
    builder: (context, _) {
      final rows = jobs.jobs;
      final problem = jobs.listError;
      final list = CustomScrollView(
        key: const ValueKey('downloader-list'),
        // A short list can still be pulled.
        physics: widget.touchInput
            ? const AlwaysScrollableScrollPhysics()
            : null,
        slivers: [
          SliverToBoxAdapter(child: _form(context)),
          SliverToBoxAdapter(child: _heading(context)),
          if (problem != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        problem.message,
                        key: const ValueKey('downloader-list-error'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (rows.isNotEmpty)
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) => _row(context, rows[index]),
            )
          else if (!jobs.loaded && problem == null)
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(semanticsLabel: 'Loading'),
                ),
              ),
            )
          else if (jobs.loaded)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Text(
                  'Paste links above to save their audio or video to your '
                  'Music or Videos folder.',
                  key: ValueKey('downloader-empty'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
        ],
      );
      return widget.touchInput
          ? RefreshIndicator(onRefresh: jobs.refresh, child: list)
          : list;
    },
  );
}

/// A row action: a labelled button in a wide window; on a phone the same
/// icon as an icon button whose tooltip and screen-reader label are the same
/// word, as the app bar and the library toolbar do.
class _JobAction {
  const _JobAction(this.key, this.icon, this.label, this.onPressed);
  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// One job: the library row's card, with the title (the link until the
/// title is known), the state in plain words, progress while downloading,
/// and where the file went or why there is none.
class _JobCard extends StatelessWidget {
  const _JobCard({super.key, required this.job, required this.actions});
  final FetchJob job;
  final List<_JobAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final downloading = job.state == FetchState.downloading;
    final percent = job.percent;
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Icon(
            switch (job.kind) {
              FetchKind.audio => Icons.music_note_outlined,
              FetchKind.video => Icons.movie_outlined,
              null => Icons.download_outlined,
            },
            color: scheme.primary,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.title ?? job.url ?? 'Download',
                  key: ValueKey('job-title:${job.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  fetchStateLabel(job),
                  key: ValueKey('job-state:${job.id}'),
                  style: job.state == FetchState.failed
                      ? small?.copyWith(color: scheme.error)
                      : small,
                ),
                if (downloading)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 2),
                    // The words above already say the percentage.
                    child: ExcludeSemantics(
                      child: LinearProgressIndicator(
                        key: ValueKey('job-progress:${job.id}'),
                        value: percent == null ? null : percent / 100,
                      ),
                    ),
                  ),
                if (job.state == FetchState.done && job.path != null)
                  Text(
                    job.path!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                if (job.isFinished && job.message != null)
                  Text(
                    job.message!,
                    key: ValueKey('job-message:${job.id}'),
                    style: small,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        // The library row's inset, including its 3 px status bar.
        padding: const EdgeInsets.fromLTRB(11, 4, 8, 4),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(child: content),
              for (final action in actions)
                if (constraints.maxWidth < 560)
                  IconButton(
                    key: ValueKey(action.key),
                    onPressed: action.onPressed,
                    tooltip: action.label,
                    icon: Icon(action.icon),
                  )
                else
                  TextButton.icon(
                    key: ValueKey(action.key),
                    onPressed: action.onPressed,
                    icon: Icon(action.icon, size: 18),
                    label: Text(action.label),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How the home tab bar lays out [labels] in [width]: equal tabs when every
/// label fits (with the usual padding, or a tighter one on a phone), and
/// otherwise tabs that scroll sideways from the start, as the Admin tabs do.
({bool scrollable, EdgeInsetsGeometry? labelPadding}) homeTabLayout(
  BuildContext context,
  List<String> labels,
  double width,
) {
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  final each = width / labels.length;
  if (widest + 32 <= each) return (scrollable: false, labelPadding: null);
  if (widest + 8 <= each) {
    return (
      scrollable: false,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
  return (scrollable: true, labelPadding: null);
}
