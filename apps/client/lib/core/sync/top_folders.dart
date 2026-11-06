/// The top-level `Documents`, `Music` and `Videos` of every root (spec #34
/// P7, decision #150): always on the device as real folders, never
/// Cloud-only, and never deleted in the cloud because they vanished here.
/// Their subfolders keep the ordinary Local / Cloud-only choice, and files
/// and folders inside them are deleted as anywhere else.
library;

const topFolders = {'Documents', 'Music', 'Videos'};

/// Whether [path] (root-relative) is one of the three folders itself.
bool isTopFolder(String path) => topFolders.contains(path);

/// The top folder [path] is in or is, or null.
String? topFolderOf(String path) {
  final slash = path.indexOf('/');
  final top = slash < 0 ? path : path.substring(0, slash);
  return topFolders.contains(top) ? top : null;
}

/// Row wording while an item of a deleted top folder comes back.
const topFolderRestoring =
    'Deleted on this device with its top folder: restoring from the cloud.';

/// Row wording once it is back.
const topFolderRestored = 'Restored from the cloud.';

const topFolderCloudOnlyRefusal =
    'Documents, Music and Videos always stay on this device. Choose '
    'Cloud-only for a folder inside them, or for their new and loose files '
    'in the folder menu.';

const topFolderDeleteRefusal =
    'Documents, Music and Videos cannot be deleted. Delete the files and '
    'folders inside them instead.';

/// The name a file or link found at [top] is moved to (never deleted):
/// `Documents (conflict copy)`, then `Documents (conflict copy 2)`, ...
/// [taken] says whether a name is already used.
String topFolderAsideName(String top, bool Function(String name) taken) {
  for (var n = 1; ; n++) {
    final name = n == 1 ? '$top (conflict copy)' : '$top (conflict copy $n)';
    if (!taken(name)) return name;
  }
}

/// The status-line notice for top folders deleted on this device:
/// [restoring] are still coming back, [restored] have just finished.
String? topFolderNotice(Iterable<String> restoring, Iterable<String> restored) {
  String names(Iterable<String> tops) {
    final list = tops.toList()..sort();
    return list.length == 1
        ? list.single
        : '${list.sublist(0, list.length - 1).join(', ')} and ${list.last}';
  }

  final notes = [
    if (restoring.isNotEmpty)
      '${names(restoring)} was deleted on this device and is being restored '
          'from the cloud; the deletion is not sent to the cloud.',
    if (restored.isNotEmpty)
      '${names(restored)} was deleted on this device and has been restored '
          'from the cloud.',
  ];
  return notes.isEmpty ? null : notes.join(' ');
}

/// A top folder's name is held by something that cannot be moved aside (a
/// FIFO, socket or device node; a Windows junction): synchronization pauses
/// and tells the user what to do. Nothing is removed.
class TopFolderBlocked implements Exception {
  const TopFolderBlocked(this.top);
  final String top;
  String get message =>
      '"$top" in your AnJ Cloud folder is not a folder: move or remove it, '
      'and AnJ Cloud creates the $top folder again.';
  @override
  String toString() => message;
}

/// Bytes for a notice: `512 B`, `3.4 MB`, `1.2 GB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
