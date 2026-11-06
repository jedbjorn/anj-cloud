import 'dart:io';

import 'model.dart';

/// Identity of synchronized rows, in memory (spec #33, decision #139).
///
/// Rows stay keyed by path in SQLite; this index maps each cloud file ID
/// (`oc:fileid`) and each local identity (`volume:inode`, the NTFS file ID on
/// Windows) to the path of the row holding it. [Manifest] builds it as rows
/// load and keeps it current on every row insert, removal and field write.
///
/// Only synchronized rows (a cloud version known) are indexed: a row the
/// scan created for a new item is not yet anyone's identity, so the old row
/// of a renamed item and the new row at its new name never collide.
///
/// Two rows claiming one identity (inode reuse the scan has not caught up
/// with, a volume key change) make that identity ambiguous: lookups return
/// null, so nothing is paired by it, and the clash is logged once. It never
/// stops a pass.
class IdentityIndex {
  final Map<int, Set<String>> _byFileId = {};
  final Map<String, Set<String>> _byLocal = {};
  final Map<String, ({int? fileId, String? local})> _of = {};
  final Set<String> _logged = {};

  /// Where a duplicate is reported (stderr; test seam).
  void Function(String message) log = stderr.writeln;

  /// Duplicates reported so far (test seam).
  int duplicatesLogged = 0;

  /// Records [entry] as the row at [path], or removes the path (null).
  void update(String path, Entry? entry) {
    final synced = entry != null && entry.etag != null;
    final fileId = synced ? entry.fileId : null;
    final local = synced ? entry.localIdentity : null;
    final old = _of[path];
    if (old?.fileId == fileId && old?.local == local) return;
    if (old != null) {
      _unlink(_byFileId, old.fileId, path);
      _unlink(_byLocal, old.local, path);
    }
    if (fileId == null && local == null) {
      _of.remove(path);
      return;
    }
    _of[path] = (fileId: fileId, local: local);
    if (fileId != null) _link(_byFileId, fileId, path, 'cloud file ID');
    if (local != null) _link(_byLocal, local, path, 'local identity');
  }

  /// The one synchronized row holding cloud file ID [id]; null when none or
  /// ambiguous.
  String? pathOfFileId(int id) => _single(_byFileId[id]);

  /// The one synchronized row holding local identity [identity]; null when
  /// none or ambiguous.
  String? pathOfLocal(String identity) => _single(_byLocal[identity]);

  /// More than one synchronized row claims [identity].
  bool localAmbiguous(String identity) => (_byLocal[identity]?.length ?? 0) > 1;

  static String? _single(Set<String>? paths) =>
      paths != null && paths.length == 1 ? paths.single : null;

  static void _unlink<K>(Map<K, Set<String>> map, K? key, String path) {
    if (key == null) return;
    final paths = map[key];
    if (paths == null) return;
    paths.remove(path);
    if (paths.isEmpty) map.remove(key);
  }

  void _link<K extends Object>(
    Map<K, Set<String>> map,
    K key,
    String path,
    String what,
  ) {
    final paths = map.putIfAbsent(key, () => {})..add(path);
    if (paths.length > 1 && _logged.add('$what $key')) {
      duplicatesLogged++;
      log(
        'anj-cloud sync: rows ${paths.toList()..sort()} share $what $key; '
        'they are not paired by it.',
      );
    }
  }
}
