import '../design/badge_palette.dart';
import '../core/sync/sync_schedule.dart';

/// Presentation-only projections. They never dispatch synchronization actions.
enum LibraryTab { home, editing, conflict }

/// The library chips, in display order (decision #56). Recent and New are
/// ranked, flat file lists; Cloud and Local filter the hierarchy.
enum LibraryPolicy { all, recent, added, cloud, local }

extension LibraryPolicyLabels on LibraryPolicy {
  String get label => switch (this) {
    LibraryPolicy.all => 'All',
    LibraryPolicy.recent => 'Recent',
    LibraryPolicy.added => 'New',
    LibraryPolicy.cloud => 'Cloud',
    LibraryPolicy.local => 'Local',
  };
  String get tooltip => switch (this) {
    LibraryPolicy.all => 'All folders and files',
    LibraryPolicy.recent => 'Files most recently changed on any device',
    LibraryPolicy.added => 'Files most recently added from any device',
    LibraryPolicy.cloud => 'Cloud folders and files',
    LibraryPolicy.local => 'Local folders and files',
  };

  /// A ranked, paged, flat list of files rather than a filtered tree.
  bool get ranked =>
      this == LibraryPolicy.recent || this == LibraryPolicy.added;
}

/// Rows a ranked list shows at first and adds with each More.
const libraryPageSize = 20;

/// Search always bypasses the chips, so only a chip with no search filters.
bool libraryFiltersActive(LibraryPolicy policy, String search) =>
    policy != LibraryPolicy.all || search.trim().isNotEmpty;

/// Whether rows are a flat list (search or a ranked chip), not a tree.
bool libraryFlat(LibraryPolicy policy, String search) =>
    search.trim().isNotEmpty || policy.ranked;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `2 Nov 2026, 14:05` in this device's local time.
String formatLibraryDate(int unixSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
    isUtc: true,
  ).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year}, ${two(t.hour)}:${two(t.minute)}';
}

/// Recent's rank: the cloud modification time, or the local one while this
/// device holds an unsynced edit (so your own pending edit is on top).
int? recentTime(Map<String, dynamic> entry) => entry['pendingLocalEdit'] == true
    ? (entry['localModified'] as int? ?? entry['remoteModified'] as int?)
    : entry['remoteModified'] as int?;

/// The date line of a ranked row.
String rankedDate(LibraryPolicy policy, Map<String, dynamic> entry) {
  if (policy == LibraryPolicy.recent) {
    final at = recentTime(entry);
    return at == null ? 'Date unknown' : 'Modified ${formatLibraryDate(at)}';
  }
  final at = entry['addedAt'] as int?;
  return at == null ? 'Added earlier' : 'Added ${formatLibraryDate(at)}';
}

/// Newest first. Recent: by [recentTime], undated last. New: by file ID,
/// which the server assigns in creation order; unidentified last. Ties and
/// the undated tail are by path, so the order is stable.
int compareRanked(
  LibraryPolicy policy,
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final (x, y) = policy == LibraryPolicy.recent
      ? (recentTime(a), recentTime(b))
      : (a['fileId'] as int?, b['fileId'] as int?);
  if (x != y) {
    if (x == null) return 1;
    if (y == null) return -1;
    return y.compareTo(x);
  }
  return (a['path'] as String).compareTo(b['path'] as String);
}

bool hasConflict(Map<String, dynamic> entry) => entry['conflict'] != null;

/// Working copies that hold an edit. Opening is not editing (decision
/// #183): an unchanged copy reads as the downloaded file it is and needs no
/// Finish editing; a later pass reclaims it.
List<Map> editedCopies(Map<String, dynamic> entry) => [
  for (final copy in (entry['workingCopies'] as List? ?? const []).cast<Map>())
    if (copy['edited'] != false) copy,
];

bool hasEditing(Map<String, dynamic> entry) =>
    editedCopies(entry).isNotEmpty || entry['finishPending'] == true;

const terminalDeletionStatuses = {
  'deleted',
  'deleted remotely',
  'removed locally',
};

/// A completed deletion with no pending operation. It is never Queued.
bool isTerminalDeletion(Map<String, dynamic> entry) =>
    terminalDeletionStatuses.contains(entry['status']) &&
    entry['syncPending'] != true &&
    entry['finishPending'] != true;

/// Bytes that existed only on this device remain in a retained copy.
bool hasRecoveryCopy(Map<String, dynamic> entry) =>
    entry['hasRecovery'] == true ||
    (entry['preservedCopies'] as List? ?? []).isNotEmpty;

bool hasQueuedWork(Map<String, dynamic> entry) {
  final status = (entry['status'] as String? ?? '').toLowerCase();
  if (entry['syncPending'] == true ||
      entry['finishPending'] == true ||
      entry['kind'] == 'unsupported') {
    return true;
  }
  if (isTerminalDeletion(entry)) return false;
  if (status.startsWith('cloud pending: editor working copies')) return false;
  return RegExp(
    r'queued|pending|uploading|downloading|awaiting|missing|error|failed|refused|unavailable',
  ).hasMatch(status);
}

/// Row badges in precedence order, highest first (decision #60).
enum RowBadge {
  recoveryCopy('Recovery copy', BadgeTone.recovery),
  conflict('Conflict', BadgeTone.attention),
  needsAttention('Needs attention', BadgeTone.attention),
  editing('Editing', BadgeTone.editing),
  queued('Queued', BadgeTone.plain),
  cloud('Cloud', BadgeTone.cloud),
  local('Local', BadgeTone.local);

  const RowBadge(this.label, this.tone);

  /// Always shown, so colour is never the only signal.
  final String label;
  final BadgeTone tone;
}

/// The single badge a row shows: the first that applies, in [RowBadge] order.
/// Needs attention uses the amber bar's predicate ([hasProblem]), so a file
/// refused as too large is never shown as Queued (SC-033).
RowBadge rowBadge(Map<String, dynamic> entry) =>
    isTerminalDeletion(entry) && hasRecoveryCopy(entry)
    ? RowBadge.recoveryCopy
    : hasConflict(entry)
    ? RowBadge.conflict
    : hasProblem(entry)
    ? RowBadge.needsAttention
    : hasEditing(entry)
    ? RowBadge.editing
    : hasQueuedWork(entry)
    ? RowBadge.queued
    : entry['effectiveRetention'] == 'cloud'
    ? RowBadge.cloud
    : RowBadge.local;

String fileBadge(Map<String, dynamic> entry) => rowBadge(entry).label;

String libraryStatus(Map<String, dynamic> entry) {
  final errors = entry['presentationErrors'] as List? ?? [];
  if (errors.isNotEmpty) return errors.join('\n');
  final status = entry['status'] as String? ?? '';
  if (status.startsWith('Cloud pending: editor working copies')) {
    return 'Editor copies remain until Finish editing. Saved changes sync automatically.';
  }
  return status;
}

/// Badges carry routine state; keep actionable and unfamiliar messages visible.
String librarySummary(Map<String, dynamic> entry) {
  final status = libraryStatus(entry);
  final lines = <String>[
    if (!const {
      '',
      'current local',
      'cloud-only',
      'working copy synchronized',
    }.contains(status))
      status,
    if (entry['conflict'] != null) entry['conflict'] as String,
    // Information lines (the cloud's name won a rename, a Windows long
    // path): never amber.
    for (final note in entry['presentationNotes'] as List? ?? const [])
      note as String,
  ];
  final artifacts = artifactSummary(entry);
  if (artifacts != null) lines.add(artifacts);
  return lines.join('\n');
}

/// Staging kinds in display order; unknown roles are counted as `other`.
const artifactKinds = ['recovery', 'upload', 'download', 'editing', 'check'];

/// Counts by kind; bytes count each distinct inode once (hard links share).
String? artifactSummary(Map<String, dynamic> entry) {
  final artifacts = entry['localArtifacts'] as Map?;
  final count = artifacts?['count'] as int? ?? 0;
  if (count == 0) return null;
  final kinds = (artifacts!['kinds'] as Map? ?? {}).cast<String, int>();
  final parts = [
    for (final kind in [...artifactKinds, 'other'])
      if ((kinds[kind] ?? 0) > 0) '$kind ${kinds[kind]}',
  ];
  return 'Local staging files: ${parts.isEmpty ? count : parts.join(', ')} (${artifacts['bytes']} bytes${artifacts['uncertain'] == true ? ', some uncertain' : ''})';
}

/// The amber bar: something here needs action. A pending finish is shown
/// amber too, but as a badge it reads Editing rather than Needs attention.
bool needsAttention(Map<String, dynamic> entry) =>
    entry['finishPending'] == true || hasProblem(entry);

/// [needsAttention] apart from a pending finish: conflicts, recovery copies,
/// and failed, refused, too-large or unsupported files.
bool hasProblem(Map<String, dynamic> entry) {
  if (hasConflict(entry) ||
      entry['kind'] == 'unsupported' ||
      entry['hasRecovery'] == true ||
      (entry['presentationErrors'] as List? ?? []).isNotEmpty ||
      (entry['preservedCopies'] as List? ?? []).isNotEmpty ||
      (entry['localArtifacts'] as Map?)?['uncertain'] == true) {
    return true;
  }
  final status = (entry['status'] as String? ?? '').toLowerCase();
  // These are ordinary editor/transfer residency, not failures.
  if (status.startsWith('cloud pending: editor working copies') ||
      status == 'cloud pending: pending work is retained.' ||
      status ==
          'cloud pending: local bytes are not yet clean and synchronized.') {
    return false;
  }
  return status.startsWith('pending:') ||
      status.startsWith('cloud pending:') ||
      RegExp(
        r'error|failed|unsupported|refused|missing|unavailable|uncertain|recovery|conflict|finish pending|working (copy|edit) pending|delete pending|awaiting server proof',
      ).hasMatch(status);
}

Iterable<String> ancestors(String path) sync* {
  final parts = path.split('/');
  for (var count = 1; count < parts.length; count++) {
    yield parts.take(count).join('/');
  }
}

bool visibleInLibrary(Map<String, dynamic> entry) {
  final status = entry['status'];
  final completedDeletion = [
    'deleted',
    'deleted remotely',
    'removed locally',
  ].contains(status);
  return !completedDeletion ||
      hasConflict(entry) ||
      hasEditing(entry) ||
      entry['syncPending'] == true ||
      entry['hasRecovery'] == true ||
      (entry['preservedCopies'] as List? ?? []).isNotEmpty ||
      ((entry['localArtifacts'] as Map?)?['count'] as int? ?? 0) > 0 ||
      (entry['localArtifacts'] as Map?)?['uncertain'] == true;
}

class LibraryRow {
  const LibraryRow(
    this.entry, {
    required this.attention,
    required this.contextOnly,
    this.syncing = false,
    this.syncingWithin = false,
    this.date,
  });
  final Map<String, dynamic> entry;

  /// Recent and New rows: the modified or added date shown with the row.
  final String? date;
  final bool attention;
  final bool contextOnly;

  /// This file is uploading, downloading or queued in the running pass.
  final bool syncing;

  /// This folder holds a syncing file at any depth.
  final bool syncingWithin;
  String get path => entry['path'] as String;
  bool get directory => entry['kind'] == 'directory';
  int get depth => path.split('/').length - 1;
}

/// The files to show as syncing, from the worker's activity set.
///
/// Rule: a file that needs attention (a failed last attempt, a conflict,
/// a recovery copy) is never shown as syncing. It stays amber and its
/// retries stay silent until one succeeds, so a file that fails every pass
/// does not flash blue on each retry. Files the catalogue does not list yet
/// (new during the running pass) are always shown.
Set<String> activeSyncing(
  List<Map<String, dynamic>> entries,
  Set<String> syncing,
) {
  if (syncing.isEmpty) return const {};
  final known = {for (final entry in entries) entry['path'] as String: entry};
  final result = <String>{};
  for (final path in syncing) {
    final entry = known[path];
    if (entry == null || (entry['kind'] == 'file' && !needsAttention(entry))) {
      result.add(path);
    }
  }
  return result;
}

/// The header status: "Syncing N files" while files transfer and nothing
/// more significant (paused, offline, needs attention) applies.
({SyncStatus status, String label}) headerStatus(
  SyncStatus status,
  int syncing,
) {
  if (syncing == 0 ||
      (status != SyncStatus.upToDate && status != SyncStatus.syncing)) {
    return (status: status, label: status.label);
  }
  return (
    status: SyncStatus.syncing,
    label: 'Syncing $syncing ${syncing == 1 ? 'file' : 'files'}',
  );
}

/// Synthetic ancestors preserve context for sparse and filtered catalogues.
/// Attention always uses every entry, including filtered/collapsed descendants.
/// [syncing] marks the same way: each syncing file and every ancestor folder
/// up to the top of the tree, whether or not the file itself is shown. The
/// catalogue arrives after each pass, so a file new during the running pass
/// gets a provisional row (synthetic, like folder context) while it syncs.
/// Text search returns files matching the full relative path, without ancestor
/// rows, under every chip (search bypasses chips; the tab still applies).
/// Recent and New return every file, ranked newest first and dated; the
/// caller pages them. Cloud/Local/tab filtering preserves the hierarchy.
/// Filters reveal paths without mutating the caller's saved collapse state.
List<LibraryRow> libraryRows(
  List<Map<String, dynamic>> entries,
  LibraryTab tab,
  Set<String> collapsed, {
  LibraryPolicy policy = LibraryPolicy.all,
  String search = '',
  Set<String> syncing = const {},
}) {
  final query = search.trim().toLowerCase();
  final revealMatches = libraryFiltersActive(policy, search);
  entries = entries.where(visibleInLibrary).toList();
  final active = activeSyncing(entries, syncing);
  if (active.isNotEmpty) {
    final listed = {for (final entry in entries) entry['path'] as String};
    for (final path in active) {
      if (!listed.contains(path)) {
        entries.add({
          'path': path,
          'kind': 'file',
          'status': '',
          'synthetic': true,
          'provisional': true,
        });
      }
    }
  }
  final all = {for (final entry in entries) entry['path'] as String: entry};
  final attention = <String>{};
  for (final entry in entries) {
    final path = entry['path'] as String;
    if (needsAttention(entry)) attention.addAll([path, ...ancestors(path)]);
    for (final parent in ancestors(path)) {
      all.putIfAbsent(
        parent,
        () => {
          'path': parent,
          'kind': 'directory',
          'status': 'Folder context',
          'synthetic': true,
        },
      );
    }
  }
  final syncingWithin = <String>{for (final path in active) ...ancestors(path)};
  LibraryRow row(String path, {required bool contextOnly, String? date}) =>
      LibraryRow(
        all[path]!,
        attention: attention.contains(path),
        contextOnly: contextOnly,
        syncing: all[path]!['kind'] == 'file' && active.contains(path),
        syncingWithin: syncingWithin.contains(path),
        date: date,
      );
  final ranked = query.isEmpty && policy.ranked;
  final matches = entries
      .where(
        (entry) =>
            ((query.isEmpty && !ranked) || entry['kind'] == 'file') &&
            (switch (tab) {
              LibraryTab.home => true,
              LibraryTab.editing => hasEditing(entry),
              LibraryTab.conflict => hasConflict(entry),
            }) &&
            // Search bypasses every chip.
            (query.isNotEmpty ||
                policy == LibraryPolicy.all ||
                // A provisional row's storage choice and times are unknown.
                (entry['provisional'] != true &&
                    (ranked ||
                        (entry['effectiveRetention'] == 'cloud'
                                ? LibraryPolicy.cloud
                                : LibraryPolicy.local) ==
                            policy))) &&
            (entry['path'] as String).toLowerCase().contains(query),
      )
      .map((entry) => entry['path'] as String)
      .toSet();
  if (query.isNotEmpty) {
    final paths = matches.toList()..sort();
    return [for (final path in paths) row(path, contextOnly: false)];
  }
  if (ranked) {
    final files = [for (final path in matches) all[path]!]
      ..sort((a, b) => compareRanked(policy, a, b));
    return [
      for (final entry in files)
        row(
          entry['path'] as String,
          contextOnly: false,
          date: rankedDate(policy, entry),
        ),
    ];
  }
  final included = <String>{...matches};
  for (final path in matches) {
    included.addAll(ancestors(path));
  }
  final children = <String, List<String>>{};
  for (final path in included) {
    final parts = path.split('/')..removeLast();
    children.putIfAbsent(parts.join('/'), () => []).add(path);
  }
  final result = <LibraryRow>[];
  void visit(String parent) {
    final paths = children[parent] ?? [];
    paths.sort((a, b) {
      final ad = all[a]!['kind'] == 'directory';
      final bd = all[b]!['kind'] == 'directory';
      if (ad != bd) return ad ? -1 : 1;
      return a.compareTo(b);
    });
    for (final path in paths) {
      result.add(row(path, contextOnly: !matches.contains(path)));
      if (revealMatches ||
          all[path]!['kind'] != 'directory' ||
          !collapsed.contains(path)) {
        visit(path);
      }
    }
  }

  visit('');
  return result;
}
