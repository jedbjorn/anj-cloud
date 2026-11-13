import 'dart:io';

import 'package:path/path.dart' as p;

import '../gateway/trash_api.dart';
import '../local/root_tree.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'recovery_copies.dart';

/// The manifest operation kind of one device-trash copy (spec #44): passive,
/// at the original path, `staged` the copy's lead staging name, `data` with
/// `at` (when it entered the trash, ms since epoch), `size`, and every
/// staging name of the same file (`names`).
const deviceTrashKind = 'trash';

/// Statuses of a completed deletion. A copy such a row still holds is a
/// deletion-produced copy: it goes to the device trash, never a row.
const deletionStatuses = {'deleted', 'deleted remotely', 'removed locally'};

/// How long trash is kept while the server has not said (spec #44).
const defaultTrashDays = 7;

class DeviceTrashItem {
  const DeviceTrashItem({
    required this.id,
    required this.path,
    required this.size,
    required this.at,
    this.changed = false,
  });
  final String id;
  final String path;
  final int size;

  /// When it entered the trash (ms since epoch).
  final int at;

  /// The deleted file held edits the server never had: these bytes, not the
  /// server's trash item, are the latest version (Undo and Restore use them).
  final bool changed;
  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'size': size,
    'at': at,
    'changed': changed,
  };
}

/// The device trash (spec #44, decision superseding #70): a deletion-produced
/// copy that the server cannot be shown to hold stays in this profile's
/// private staging area, outside the synchronized root, as a trash record
/// instead of a Recovery row. It is purged automatically [days] after the
/// deletion; Restore puts it back with spec #25's crash-safe write, never
/// replacing anything. Conflict, upload-recovery and eviction copies of live
/// rows are not touched.
class DeviceTrash {
  DeviceTrash(
    this.manifest,
    this.tree,
    this.recovery, {
    required this.clock,
    required this.restored,
  });
  final Manifest manifest;
  final RootTree tree;
  final RecoveryCopies recovery;
  final DateTime Function() clock;

  /// Called with a root path a restore created, so the next pass reads it.
  final void Function(String path) restored;

  static const daysSetting = 'trashDays';

  /// The retention the server advertised (`trash_days`), 7 while unknown.
  int get days {
    final value = int.tryParse(manifest.setting(daysSetting) ?? '');
    return value != null && value >= 1 ? value : defaultTrashDays;
  }

  set days(int value) {
    if (value >= 1 && value != days) {
      manifest.setSetting(daysSetting, '$value');
    }
  }

  int get _now => clock().millisecondsSinceEpoch;

  static const serverSetting = 'serverTrash';
  static const checkedSetting = 'serverTrashChecked';

  /// The server has the gateway's trash routes (seen at a pass or in the
  /// Trash view). Until it has, a deleted file's copy is kept here even when
  /// the server held the same bytes: an older gateway gives no way back.
  bool get serverTrash => manifest.setting(serverSetting) == 'yes';

  /// Whether a pass should ask the server again: about once a day.
  bool get checkDue {
    final at = int.tryParse(manifest.setting(checkedSetting) ?? '');
    return at == null ||
        at > _now ||
        _now - at >= Duration.millisecondsPerDay ||
        manifest.setting(serverSetting) == null;
  }

  /// What the server answered: its trash (routes and `trash_days`), or null
  /// for a gateway without them.
  void learned(ServerTrash? listed) {
    manifest.setSetting(serverSetting, listed == null ? 'no' : 'yes');
    if (listed != null) days = listed.trashDays;
    manifest.setSetting(checkedSetting, '$_now');
  }

  Iterable<Operation> get records =>
      manifest.operations.values.where((o) => o.kind == deviceTrashKind);

  /// Every staging name a trash record holds; such names are no row's copy.
  Set<String> get held => {
    for (final record in records) ...[
      ?record.staged,
      ...(record.data['names'] as List? ?? const []).cast<String>(),
    ],
  };

  List<DeviceTrashItem> items() =>
      [
        for (final record in records)
          DeviceTrashItem(
            id: record.id,
            path: record.path,
            size: record.data['size'] as int? ?? 0,
            at: record.data['at'] as int? ?? _now,
            changed: record.data['changed'] == true,
          ),
      ]..sort((a, b) {
        final order = b.at.compareTo(a.at);
        return order != 0 ? order : a.path.compareTo(b.path);
      });

  int get bytes => items().fold(0, (sum, item) => sum + item.size);

  /// Moves the copy each completed deletion produced into the trash (also the
  /// migration of rows left by earlier versions, T7: their clock starts now):
  /// the bytes a deletion preserved, or the snapshot of a file removed before
  /// it ever uploaded. Every other copy of the row (a replacement, eviction or
  /// conflict copy, a leftover snapshot) keeps its Recovery row (spec #44).
  /// A row with pending work, a conflict about something other than its
  /// copy, or a copy whose ownership is uncertain keeps its row too. Returns
  /// how many copies moved.
  int collect() {
    var moved = 0;
    final now = _now;
    final serverTrash = this.serverTrash;
    for (final entry in manifest.entries.values.toList()) {
      if (!deletionStatuses.contains(entry.status)) continue;
      if (entry.conflict != null &&
          !copyOnlyConflicts.contains(entry.conflict)) {
        continue;
      }
      if (manifest
          .operationsAt(entry.path)
          .any((o) => !_passive.contains(o.kind))) {
        continue;
      }
      final copies = recovery.copiesOf(entry.path);
      if (copies.isEmpty) continue;
      var changed = false;
      var kept = false;
      for (final group in RecoveryCopies.byFile(copies)) {
        final present = group.where((c) => c.info != null).toList();
        if (present.isEmpty) {
          for (final c in group) {
            recovery.forget(c.staged, c.record);
          }
          continue;
        }
        final names = {for (final c in present) c.staged};
        final deletion = manifest.operations.values
            .where(
              (o) =>
                  o.kind == 'retained' &&
                  o.path == entry.path &&
                  names.contains(o.staged) &&
                  (o.data['deletion'] == true ||
                      o.data['unsyncedRemoval'] == true),
            )
            .firstOrNull;
        if (deletion == null || !present.every(recovery.owned)) {
          kept = true;
          continue;
        }
        final edited =
            deletion.data['localChanged'] == true ||
            entry.conflict == preservedChangedConflict;
        // A copy of a version the server holds waits for spec #12 rule 2
        // (released once nothing holds it open) when the server has a trash
        // to restore from; a copy found changed comes here at once.
        if (serverTrash &&
            !edited &&
            entry.conflict == null &&
            deletion.data['deletion'] == true &&
            deletion.data['deletedVersionHash'] != null) {
          kept = true;
          continue;
        }
        final lead = present.first;
        // The same bytes of the same deletion already in the trash (a deletion
        // copy and the snapshot of an upload that never finished): one entry;
        // this copy is released under the guard once it verifies identical.
        final twin = _twin(entry.path, lead, now);
        if (twin != null) {
          try {
            recovery.removeNamesVerified(present, entry.path, twin);
            changed = true;
          } on FileSystemException {
            kept = true;
          }
          continue;
        }
        final record =
            Operation(
                uniqueId(),
                deviceTrashKind,
                entry.path,
                staged: lead.staged,
                hash: lead.record?.hash ?? deletion.hash,
              )
              ..data = {
                'at': now,
                'size': lead.info!.size,
                'names': [for (final c in present) c.staged],
                if (edited) 'changed': true,
              };
        manifest.operations[record.id] = record;
        for (final c in present) {
          manifest.operations.removeWhere(
            (_, o) => o.kind == 'retained' && o.staged == c.staged,
          );
          entry.preservedCopies.remove(c.staged);
        }
        changed = true;
        moved++;
      }
      // The conflict only described the copy, which is now in the trash.
      if (changed && !kept && copyOnlyConflicts.contains(entry.conflict)) {
        entry.conflict = null;
      }
      if (changed) manifest.save();
    }
    return moved;
  }

  /// The content hash of the trash record for [path] made within
  /// [sameDeletion] of [now] that holds exactly [copy]'s bytes, else null.
  String? _twin(String path, RecoveryCopy copy, int now) {
    final recent = records
        .where(
          (r) =>
              r.path == path &&
              ((r.data['at'] as int? ?? now) - now).abs() <=
                  sameDeletion.inMilliseconds,
        )
        .toList();
    if (recent.isEmpty) return null;
    final hash = _hash(copy);
    if (hash == null) return null;
    for (final record in recent) {
      var known = record.data['sha'] as String?;
      if (known == null) {
        final lead = recovery
            .trashCopies(record)
            .where((c) => c.info != null)
            .firstOrNull;
        known = lead == null ? null : _hash(lead);
        if (known != null) record.data['sha'] = known;
      }
      if (known == hash) return hash;
    }
    return null;
  }

  String? _hash(RecoveryCopy copy) {
    try {
      return tree.native.copyAndHash(
        tree.stageFd,
        p.basename(copy.staged),
        null,
        purpose: 'trash-twin',
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Removes copies older than [days] (more than exactly that long ago) and
  /// records whose file is gone. One that cannot be removed now (busy,
  /// changed) is retried at the next pass. Returns how many went.
  int purge() {
    final limit = days * Duration.millisecondsPerDay;
    final now = _now;
    var removed = 0;
    for (final record in records.toList()) {
      final at = record.data['at'] as int? ?? now;
      final names = recovery.trashCopies(record);
      if (names.every((c) => c.info == null)) {
        for (final c in names) {
          recovery.forget(c.staged, c.record);
        }
        manifest.operations.remove(record.id);
        manifest.save();
        continue;
      }
      if (now - at <= limit) continue;
      if (_discard(record)) removed++;
    }
    return removed;
  }

  bool _discard(Operation record) {
    try {
      recovery.removeNames(recovery.trashCopies(record), record.path);
    } on FileSystemException {
      return false;
    }
    manifest.operations.remove(record.id);
    manifest.save();
    return true;
  }

  /// Delete now (spec #44): the copy goes at once, permanently.
  void delete(String id) {
    final record = _record(id);
    if (!_discard(record)) {
      throw const FileSystemException(
        'This copy is open in another program or changed; it is kept.',
      );
    }
  }

  /// Empty Trash on this device. Returns how many copies went; one that
  /// cannot be removed now stays.
  int empty() {
    var removed = 0;
    for (final record in records.toList()) {
      if (_discard(record)) removed++;
    }
    return removed;
  }

  /// A copy whose bytes the live file at its path now holds (a restore from
  /// the server, an Undo) is redundant and released, like spec #12 rule 2.
  void releaseRestored() {
    for (final record in records.toList()) {
      final entry = manifest.entries[record.path];
      if (record.hash == null ||
          entry == null ||
          entry.etag == null ||
          entry.conflict != null ||
          entry.baselineHash != record.hash ||
          manifest
              .operationsAt(record.path)
              .any((o) => !_passive.contains(o.kind))) {
        continue;
      }
      try {
        recovery.removeNamesVerified(
          recovery.trashCopies(record),
          record.path,
          record.hash!,
        );
      } on FileSystemException {
        continue;
      }
      manifest.operations.remove(record.id);
      manifest.save();
    }
  }

  /// Restores copy [id] to its original path, or `name (restored).ext` when
  /// that is taken; missing folders are created again. Returns where it went.
  Map<String, Object?> restore(String id) {
    final record = _record(id);
    final path = record.path;
    var folder = p.posix.dirname(path);
    while (folder != '.') {
      if (manifest.operationsAt(folder).any((o) => o.kind == 'delete')) {
        throw const FileSystemException(
          'Its folder is being deleted. Try again shortly.',
        );
      }
      folder = p.posix.dirname(folder);
    }
    tree.native.checkRoot(tree.fd, tree.root.path);
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    final destination = recovery.trashDestination(path);
    final parent = p.posix.dirname(destination);
    if (parent != '.') {
      // A folder that was deleted comes back as a new folder: its old row
      // (a completed deletion) is forgotten so the next pass uploads it.
      var ancestor = parent;
      while (ancestor != '.') {
        final row = manifest.entries[ancestor];
        if (row != null &&
            deletionStatuses.contains(row.status) &&
            row.kind == ItemKind.directory &&
            !manifest
                .operationsAt(ancestor)
                .any((o) => o.kind != deviceTrashKind)) {
          manifest.entries.remove(ancestor);
        }
        ancestor = p.posix.dirname(ancestor);
      }
      manifest.save();
      tree.ensureDirectory(parent);
      restored(parent);
    }
    final result = recovery.restoreTrash(record, destination);
    // The file comes back as a new file: the completed deletion's row (whose
    // baseline may be these very bytes) would otherwise never upload it.
    final row = manifest.entries[destination];
    if (row != null &&
        deletionStatuses.contains(row.status) &&
        row.etag == null &&
        !manifest
            .operationsAt(destination)
            .any((o) => !_passive.contains(o.kind))) {
      manifest.entries.remove(destination);
      manifest.save();
    }
    restored(destination);
    return result;
  }

  Operation _record(String id) {
    final record = manifest.operations[id];
    if (record == null || record.kind != deviceTrashKind) {
      throw const FileSystemException('No longer in Trash');
    }
    return record;
  }
}

const _passive = {
  'artifact',
  'retained',
  'excluded-entry',
  'excluded-operation',
  deviceTrashKind,
};

/// One Trash view entry (spec #44): a server item, a device copy, or both
/// for the same path and deletion.
class TrashEntry {
  TrashEntry({this.server, this.device});
  final ServerTrashItem? server;
  final DeviceTrashItem? device;

  String get path => server?.path ?? device!.path;

  /// Deletion time, ms since epoch.
  int get deleted => server != null ? server!.deleted * 1000 : device!.at;
  int get size =>
      device?.changed == true ? device!.size : server?.size ?? device!.size;
  bool get folder => server?.folder ?? false;

  Map<String, Object?> toJson(int days) => {
    'path': path,
    'kind': folder ? 'folder' : 'file',
    'size': size,
    'deleted': deleted,
    'expires': server != null
        ? server!.expires * 1000
        : device!.at + days * Duration.millisecondsPerDay,
    'serverId': server?.id,
    'deviceId': device?.id,
    'deviceSize': device?.size,
    'onlyDevice': server == null,
    // The device copy holds edits the server never had: Restore uses it.
    'deviceFirst': device?.changed == true,
  };
}

/// How far apart a server item's deletion and a device copy's may be and
/// still be one deletion: the copy enters the trash at the pass that saw
/// the deletion, normally seconds later.
const sameDeletion = Duration(minutes: 30);

/// One entry per deletion, newest first: a device copy joins the server item
/// of the same path whose deletion is closest in time (within
/// [sameDeletion]); the rest stand alone.
List<TrashEntry> mergeTrash(
  List<ServerTrashItem> server,
  List<DeviceTrashItem> device,
) {
  final entries = [for (final item in server) TrashEntry(server: item)];
  final joined = <int, DeviceTrashItem>{};
  final alone = <DeviceTrashItem>[];
  for (final copy in device) {
    int? best;
    for (var i = 0; i < entries.length; i++) {
      final item = entries[i].server!;
      if (item.path != copy.path || item.folder || joined.containsKey(i)) {
        continue;
      }
      final gap = (item.deleted * 1000 - copy.at).abs();
      if (gap > sameDeletion.inMilliseconds) continue;
      if (best == null ||
          gap < (entries[best].server!.deleted * 1000 - copy.at).abs()) {
        best = i;
      }
    }
    if (best == null) {
      alone.add(copy);
    } else {
      joined[best] = copy;
    }
  }
  return [
    for (var i = 0; i < entries.length; i++)
      TrashEntry(server: entries[i].server, device: joined[i]),
    for (final copy in alone) TrashEntry(device: copy),
  ]..sort((a, b) {
    final order = b.deleted.compareTo(a.deleted);
    return order != 0 ? order : a.path.compareTo(b.path);
  });
}
