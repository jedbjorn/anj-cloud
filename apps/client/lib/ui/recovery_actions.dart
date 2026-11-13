import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/sync/bulk_targets.dart';
import '../core/state/model.dart';

/// Recover and Dismiss (spec #25): presentation of a row's retained
/// recovery copies, as projected by the worker (`recoveryCopies`).
Map<String, dynamic>? _copies(Map<String, dynamic> entry) =>
    (entry['recoveryCopies'] as Map?)?.cast<String, dynamic>();

List<String> recoveryCopyPaths(Map<String, dynamic> entry) =>
    (_copies(entry)?['paths'] as List? ?? const []).cast<String>();

/// The row holds at least one retained recovery copy: Recover and Dismiss
/// are offered.
bool hasRecoveryCopies(Map<String, dynamic> entry) =>
    entry['synthetic'] != true && recoveryCopyPaths(entry).isNotEmpty;

/// At least one copy is present and owned, so Recover can restore it.
bool canRecover(Map<String, dynamic> entry) =>
    _copies(entry)?['recoverable'] == true;

int recoveryBytes(Map<String, dynamic> entry) =>
    _copies(entry)?['bytes'] as int? ?? 0;

int recoveryCount(Map<String, dynamic> entry) =>
    _copies(entry)?['count'] as int? ?? 0;

/// A completed deletion kept only for its copies: in Select mode it is
/// selectable for Dismiss and for nothing else.
bool dismissOnly(Map<String, dynamic> entry) =>
    deletedSelectionStatus(entry['status'] as String?);

bool sameRecoveryCopies(Map<String, dynamic> a, Map<String, dynamic> b) {
  final x = recoveryCopyPaths(a);
  final y = recoveryCopyPaths(b);
  return x.length == y.length &&
      Iterable<int>.generate(x.length).every((i) => x[i] == y[i]);
}

/// What the worker deletes: exactly the copies the user confirmed.
Map<String, dynamic> dismissTarget(Map<String, dynamic> entry) => {
  'path': entry['path'],
  'kind': entry['kind'],
  'copies': recoveryCopyPaths(entry),
};

/// Total bytes of [entries]' copies, each file once even when rows share
/// it (by staging file identity; rows without identities count their own
/// deduplicated total).
int recoveryTotalBytes(List<Map<String, dynamic>> entries) {
  final seen = <String>{};
  var total = 0;
  for (final entry in entries) {
    final files = _copies(entry)?['files'] as List?;
    if (files == null) {
      total += recoveryBytes(entry);
      continue;
    }
    for (final file in files.cast<Map>()) {
      if (seen.add(file['identity'] as String)) total += file['size'] as int;
    }
  }
  return total;
}

String dismissTitle(List<Map<String, dynamic>> entries) =>
    entries.length == 1 && recoveryCount(entries.single) <= 1
    ? 'Delete recovery copy?'
    : 'Delete recovery copies?';

/// One confirmation naming the file(s), the total size, and that the copy
/// is the only one and cannot be undone (decision #57).
String dismissPrompt(List<Map<String, dynamic>> entries) {
  final size = sizeLabel(recoveryTotalBytes(entries));
  if (entries.length == 1) {
    final entry = entries.single;
    final name = p.posix.basename(_shown(entry));
    final count = recoveryCount(entry);
    return count <= 1
        ? 'Delete the recovery copy of $name ($size)? It is the only copy and cannot be undone.'
        : 'Delete the $count recovery copies of $name ($size)? They are the only copies and cannot be undone.';
  }
  return 'Delete the recovery copies of ${entries.length} files ($size)? They are the only copies and cannot be undone.\n\n${entries.map(_shown).join('\n')}';
}

/// The name a row is shown under: its cloud spelling, never this device's
/// local alias (spec #49, decision #193).
String _shown(Map<String, dynamic> entry) =>
    (entry['cloudPath'] ?? entry['path']) as String;

Future<bool> confirmDismiss(
  BuildContext context,
  List<Map<String, dynamic>> entries, {
  void Function(BuildContext dialog)? opened,
}) async {
  final plural = dismissTitle(entries) == 'Delete recovery copies?';
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      opened?.call(dialog);
      return AlertDialog(
        title: Text(dismissTitle(entries)),
        scrollable: true,
        content: Text(dismissPrompt(entries)),
        actions: [
          TextButton(
            key: const ValueKey('cancel-dismiss'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-dismiss'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
              foregroundColor: Theme.of(dialog).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(plural ? 'Delete copies' : 'Delete copy'),
          ),
        ],
      );
    },
  );
  return yes == true;
}

/// The outcome of a Recover, for a snackbar.
String recoverMessage(Map<String, dynamic> result, {required bool paused}) {
  final errors = (result['errors'] as List? ?? const []).cast<String>();
  if (errors.isNotEmpty) return 'Could not recover ${errors.join('\n')}';
  final restored = (result['restored'] as List? ?? const []).cast<Map>();
  if (restored.isEmpty) return 'Nothing was recovered.';
  final r = restored.first;
  final path = r['path'] as String;
  final destination = r['destination'] as String;
  final name = p.posix.basename(path);
  final where = destination == path
      ? 'Recovered $name.'
      : p.posix.dirname(destination) != p.posix.dirname(path)
      // Its folder was deleted; never recreated (spec #25 ruling).
      ? 'Restored to $destination. Its folder ${p.posix.dirname(path)} no longer exists.'
      : 'Recovered $name as ${p.posix.basename(destination)}.';
  final sync = paused
      ? ' It uploads after you resume sync.'
      : ' It syncs normally.';
  final kept = r['unconfirmed'] == true
      ? ' The disk did not confirm the restored file was saved, so the recovery copy was kept.'
      : r['kept'] == true
      ? ' The recovery copy was kept because the restored file could not be verified.'
      : '';
  return '$where$sync$kept';
}

/// The outcome of a Dismiss, for a snackbar.
String dismissMessage(Map<String, dynamic> result) {
  final errors = (result['errors'] as List? ?? const []).cast<String>();
  final accepted = result['accepted'] as int? ?? 0;
  final done = accepted == 0
      ? ''
      : accepted == 1
      ? 'Recovery copy deleted.'
      : 'Recovery copies of $accepted files deleted.';
  if (errors.isEmpty) return done;
  return '${done.isEmpty ? '' : '$done\n'}Kept: ${errors.join('\n')}';
}
