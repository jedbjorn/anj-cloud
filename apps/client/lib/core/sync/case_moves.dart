import 'package:path/path.dart' as p;

import 'name_policy.dart';

/// Renames that change only case or Unicode normalization (SC-054).
///
/// A synchronized item renamed `Photos` -> `photos` is seen as the old name
/// gone and a new name present. Under decision #120 the new name clashes
/// with the old one until it is gone, so treating the pair as a deletion
/// plus a create stalls (or re-uploads a whole folder). Pairing them lets
/// the engine move the item instead: one cloud MOVE (or one local rename)
/// carries the item and its subtree.
///
/// Pairs each of [vanished] with the one path of [appeared] in the same
/// folder whose name differs from it only by case or normalization. A name
/// with more than one such partner on either side stays unpaired, as does a
/// path whose folder itself changed spelling: the folder's own move covers
/// it, and anything left under it pairs on a later pass.
Map<String, String> pairRenames(
  Iterable<String> vanished,
  Iterable<String> appeared,
) {
  final come = <String, List<String>>{};
  for (final path in appeared) {
    come.putIfAbsent(_key(path), () => []).add(path);
  }
  if (come.isEmpty) return const {};
  final gone = <String, List<String>>{};
  for (final path in vanished) {
    final key = _key(path);
    if (come.containsKey(key)) gone.putIfAbsent(key, () => []).add(path);
  }
  return {
    for (final MapEntry(:key, value: from) in gone.entries)
      if (from.length == 1 && come[key]!.length == 1)
        from.single: come[key]!.single,
  };
}

String _key(String path) =>
    '${p.posix.dirname(path)}/${NamePolicy.foldKey(p.posix.basename(path))}';

/// [path] is [root] or beneath it.
bool withinOrAt(String root, String path) =>
    path == root || p.posix.isWithin(root, path);

/// [path] under [from] re-rooted at [to].
String renamedPath(String from, String to, String path) =>
    path == from ? to : '$to${path.substring(from.length)}';

/// The row at the old path of a local move whose new path cannot sync
/// (spec #33 I1 step 5: a blocked name or a paused owner). The cloud item
/// stays there, never deleted; the new row shows the reason.
const movedHereStatus =
    'Moved on this device; kept here in the cloud until the new name can sync';

/// The row of an item the cloud renamed to a name another local item still
/// holds here: the clash partner whose removal frees it (spec #49 AC7),
/// applied later in the pass, or an item of this device not synchronized
/// yet. It keeps its place until the name is free.
const renamePendingStatus =
    'rename pending: another item here has the new name';

/// The same, for a move to a name that is never synchronized (an
/// exclusion): the new item has no row, so the old one says why.
String movedNotSyncedStatus(String name) =>
    "Moved to $name, which isn't synced";

/// Either status of a parked move's old row.
bool isMovedHereStatus(String status) =>
    status == movedHereStatus ||
    (status.startsWith('Moved to ') && status.endsWith(", which isn't synced"));
