/// Retained recovery/scaffold rows remain visible but are no longer targets
/// of Delete or storage choices. A recovery row of this kind is selectable
/// for Dismiss only (spec #25, `recovery_actions.dart` [dismissOnly]).
bool deletedSelectionStatus(String? status) =>
    status != null &&
    (status.startsWith('deleted') || status == 'removed locally');

/// Keep only explicitly selected roots for deletion. Folder descendants are
/// covered by their selected ancestor; similarly named siblings remain separate.
/// The caller must validate every supplied target before applying this result.
List<T> canonicalDeleteTargets<T>(
  List<T> targets, {
  required String Function(T) pathOf,
  required bool Function(T) isDirectory,
}) {
  final directories = targets.where(isDirectory).map(pathOf).toSet();
  return targets.where((target) {
    var path = pathOf(target);
    for (
      var slash = path.lastIndexOf('/');
      slash >= 0;
      slash = path.lastIndexOf('/')
    ) {
      path = path.substring(0, slash);
      if (directories.contains(path)) return false;
    }
    return true;
  }).toList();
}
