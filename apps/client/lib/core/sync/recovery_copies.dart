import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import '../ports/release_guard.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';
import 'staging_release.dart';
import 'sync_path_policy.dart';

/// Conflicts whose only subject is a retained copy (decision #37). Once the
/// row holds no copy, the conflict has nothing left to describe.
const replacementRetainedConflict =
    'A replacement root file and recovery copy are both retained.';
const rootReplacedConflict =
    'Root path was replaced during Cloud recovery. Both local copies remain.';
const quarantineChangedConflict =
    'Quarantined local content changed. Complete recovery bytes are retained.';
const preservedChangedConflict =
    'A preserved local version changed after replacement or deletion. Its complete bytes are retained.';
const copyOnlyConflicts = {
  replacementRetainedConflict,
  rootReplacedConflict,
  quarantineChangedConflict,
  preservedChangedConflict,
};

const _terminalStatuses = {'deleted', 'deleted remotely', 'removed locally'};

/// Operations that never make a path busy or hold a staging file in use.
const _passive = {
  'artifact',
  'retained',
  'trash',
  'excluded-entry',
  'excluded-operation',
};

/// One retained copy of a row: its staging path, its ownership record (null
/// when none is known) and its file as it stands now (null when absent).
class RecoveryCopy {
  RecoveryCopy(this.staged, this.record, this.info, {required this.retained});
  final String staged;
  final Operation? record;
  final NativeFileInfo? info;

  /// Explicitly retained (a `retained` operation or a preserved copy), as
  /// opposed to a leftover staging file of the row.
  final bool retained;
  String get name => p.basename(staged);
}

/// Recover and Dismiss (spec #25, decision #57): local-only actions on the
/// retained recovery copies of one library row.
///
/// Recover copies the newest copy into a recorded staging file, fsyncs and
/// re-reads it, then renames it into the root without replacing anything.
/// The copy is released only once the restored file in the root reads back
/// with the same hash as the copy (re-hashed under the release guard).
///
/// Dismiss records its intent on each copy, unlinks it under the guard and
/// then removes every reference in one manifest transaction. Recovery after
/// a crash ([recoverInterrupted]) leaves each copy either listed and present
/// or gone with no reference.
class RecoveryCopies {
  RecoveryCopies(
    this.manifest,
    this.tree,
    this.artifacts, {
    required this.recordsFor,
    required this.restored,
    this.localIdentities = const {},
  });
  final Manifest manifest;
  final RootTree tree;
  final Artifacts artifacts;

  /// Owned staging records attributed to a path (the engine's index).
  final List<Operation> Function(String path) recordsFor;

  /// Called with a root path Recover created, so the next pass reads it.
  final void Function(String path) restored;

  /// Root path -> file identity from the last local scan (the engine's).
  final Map<String, String?> localIdentities;

  /// Synchronous test hook at exact crash/order boundaries; absent in the app.
  void Function(String point, Operation record)? barrier;

  /// Copies [name] from staging into [target] and returns the hash of the
  /// bytes read. A test seam for a failing write (a full disk).
  late String Function(String name, File target) copy = (name, target) =>
      tree.native.copyAndHash(tree.stageFd, name, target, purpose: 'recover');

  /// Renames staging [name] to root [path] (no replace, both directories
  /// fsynced). A test seam for a failing fsync after the rename.
  late void Function(String path, String name) rename = (path, name) =>
      artifacts.native.restore(tree.fd, path, tree.stageFd, name);

  NativeFileInfo? _info(String name) {
    try {
      return artifacts.native.info(tree.stageFd, name);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  bool _busy(String path) => manifest
      .operationsAt(path)
      .any(
        (o) => StagingRelease.busyKinds.contains(o.kind) || o.kind == 'recover',
      );

  bool _terminal(Entry entry) =>
      _terminalStatuses.contains(entry.status) &&
      !manifest.operationsAt(entry.path).any((o) => !_passive.contains(o.kind));

  /// Another row also lists [staged] as its copy: Dismiss and Recover then
  /// drop only this row's reference and never delete the bytes.
  bool _sharedElsewhere(String staged, String row) =>
      manifest.operations.values.any(
        (o) => o.kind == 'retained' && o.staged == staged && o.path != row,
      ) ||
      manifest.entries.values.any(
        (e) => e.path != row && e.preservedCopies.contains(staged),
      );

  /// A file that is itself a live, tracked file in the sync folder (the same
  /// inode, e.g. a hard link made by installOwned) is never a recovery copy
  /// (spec #25 ruling). Decided by identity and manifest tracking, never by
  /// name or link count (PR #60 F3): the copy is live when a tracked root
  /// file is this same file. A platform that cannot link (Android) renames
  /// installs instead, so no staging name of a live file remains there.
  bool _live(NativeFileInfo info, Operation? record, String row) {
    bool tracked(String path) {
      final entry = manifest.entries[path];
      return entry != null && entry.kind == ItemKind.file;
    }

    for (final path in {
      row,
      if (record != null) ...[
        record.path,
        if (record.data['entryPath'] is String)
          record.data['entryPath'] as String,
      ],
    }) {
      if (!tracked(path)) continue;
      try {
        if (artifacts.native.info(tree.fd, path).identity == info.identity) {
          return true;
        }
      } on FileSystemException {
        // Absent or unreadable here; the scan below still applies.
      }
    }
    // The last scan may be stale: a match there is confirmed by a fresh
    // stat of that path before it counts.
    for (final item in localIdentities.entries) {
      if (item.value != info.identity || !tracked(item.key)) continue;
      try {
        if (artifacts.native.info(tree.fd, item.key).identity ==
            info.identity) {
          return true;
        }
      } on FileSystemException {
        // Gone since the scan.
      }
    }
    return false;
  }

  /// Staging paths in use by pending work or by an entry's conflict state.
  bool _inUse(String staged) =>
      manifest.operations.values.any(
        (o) => o.staged == staged && !_passive.contains(o.kind),
      ) ||
      manifest.entries.values.any(
        (e) => e.remoteCopy == staged || e.workingCopy == staged,
      );

  /// Every retained copy [path] holds, whatever produced it:
  /// - `retained` operations and preserved copies: deletion (`preserved`),
  ///   an upload snapshot of a file removed before it synced (SC-028), an
  ///   eviction quarantine kept beside a replacement, an editor completion
  ///   slot kept for recovery;
  /// - staging records of a recovery kind: `conflict-local` and
  ///   `conflict-edited-copy` copies made by Keep both;
  /// - for a completed deletion, every other owned staging file of the row
  ///   (it is gone from the root and the cloud; they are leftovers);
  /// - owned hard-link aliases of any of the above (same bytes).
  List<RecoveryCopy> copiesOf(String path) {
    final entry = manifest.entries[path];
    if (entry == null) return const [];
    final explicit = <String>{
      for (final op in manifest.operationsAt(path))
        if (op.kind == 'retained' && op.staged != null) op.staged!,
      ...entry.preservedCopies,
    };
    final records = recordsFor(path);
    final terminal = _terminal(entry);
    // Never excluded by role: a copy is left out only while it is a live
    // tracked file ([_live]) or, for a live synced row, the synced bytes.
    bool implicit(Operation record) =>
        record.staged != null &&
        (terminal ||
            artifactKind(record.data['role'] as String?) == 'recovery');
    if (explicit.isEmpty && !records.any(implicit)) {
      return const [];
    }
    final staged = <String>{
      ...explicit,
      for (final record in records)
        if (implicit(record)) record.staged!,
    };
    final byStaged = {
      for (final record in artifacts.records)
        if (record.staged != null) record.staged!: record,
    };
    final copies = <RecoveryCopy>[];
    for (final path in staged) {
      // In use by pending work (an editor, a conflict's cloud copy): not
      // offered until that work ends.
      if (_inUse(path)) continue;
      final record = byStaged[path];
      NativeFileInfo? info;
      try {
        info = _info(p.basename(path));
      } on FileSystemException {
        info = null;
      }
      if (info != null && _live(info, record, entry.path)) continue;
      if (!explicit.contains(path) && _redundant(record, entry)) continue;
      copies.add(
        RecoveryCopy(path, record, info, retained: explicit.contains(path)),
      );
    }
    // Owned aliases: other names for the same bytes.
    final identities = {
      for (final c in copies)
        if (c.info != null) c.info!.identity,
    };
    for (final record in records) {
      if (record.staged == null ||
          staged.contains(record.staged) ||
          _inUse(record.staged!)) {
        continue;
      }
      final info = _info(p.basename(record.staged!));
      if (info != null &&
          identities.contains(info.identity) &&
          !_live(info, record, entry.path)) {
        copies.add(RecoveryCopy(record.staged!, record, info, retained: false));
      }
    }
    copies.sort((a, b) => a.staged.compareTo(b.staged));
    return copies;
  }

  /// A separate snapshot of a live, synced row holding exactly its synced
  /// bytes (e.g. Keep both's `conflict-local` snapshot when the root was
  /// unchanged) is not "the only copy". Never applied to explicitly
  /// retained copies or to a completed deletion's leftovers.
  static bool _redundant(Operation? record, Entry entry) =>
      record != null &&
      record.hash != null &&
      entry.expectedPresent &&
      entry.etag != null &&
      entry.conflict == null &&
      record.hash == entry.baselineHash;

  /// The row's copies for the library: staging paths, total bytes (each
  /// distinct file once) and whether any copy's ownership is uncertain.
  Map<String, Object?>? describe(String path) {
    final copies = copiesOf(path);
    if (copies.isEmpty) return null;
    final inodes = <String>{};
    var bytes = 0;
    for (final c in copies) {
      if (c.info != null && inodes.add(c.info!.identity)) bytes += c.info!.size;
    }
    return {
      'paths': [for (final c in copies) c.staged],
      // Identity and size per present copy, so a bulk total counts each
      // file once even when rows share one.
      'files': [
        for (final c in copies)
          if (c.info != null)
            {'identity': c.info!.identity, 'size': c.info!.size},
      ],
      'count': inodes.length,
      'bytes': bytes,
      'recoverable': copies.any(_owned),
    };
  }

  bool _owned(RecoveryCopy c) =>
      c.info != null &&
      c.record != null &&
      c.record!.phase == 'complete' &&
      c.record!.data['identity'] == c.info!.identity &&
      c.record!.data['directoryIdentity'] == tree.native.identity(tree.stageFd);

  /// Recover or dismiss each target; one failure never stops the others.
  /// Dismiss targets carry `copies`, the staging paths the user confirmed:
  /// only those are deleted, so a copy that appeared since is kept.
  Map<String, Object?> apply(
    String action,
    List<Map<String, dynamic>> targets,
  ) {
    if (!{'recover', 'dismiss'}.contains(action) || targets.isEmpty) {
      throw const FileSystemException('Choose a recovery copy and an action.');
    }
    tree.native.checkRoot(tree.fd, tree.root.path);
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    recoverInterrupted();
    var accepted = 0;
    final errors = <String>[];
    final restored = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final target in targets) {
      final path = target['path'] as String;
      try {
        validateRelative(path);
        if (!seen.add(path)) {
          throw const FileSystemException('Duplicate target.');
        }
        if (action == 'recover') {
          restored.add(recover(path));
        } else {
          dismiss(path, (target['copies'] as List? ?? []).cast<String>());
        }
        accepted++;
      } on FileSystemException catch (error) {
        errors.add('$path: ${_message(error)}');
      }
    }
    return {
      'accepted': accepted,
      'failed': targets.length - accepted,
      'errors': errors,
      'restored': restored,
    };
  }

  static String _message(Object error) => switch (error) {
    FileSystemException(:final message, :final osError)
        when osError?.errorCode == 28 =>
      'Not enough disk space. $message',
    FileSystemException(:final message) => message,
    _ => '$error',
  };

  void _requireIdle(String path) {
    if (_busy(path)) {
      throw const FileSystemException(
        'This file has pending sync work. Try again once it finishes.',
      );
    }
  }

  // ---------------------------------------------------------------- Dismiss

  /// Deletes the confirmed copies of [path]. Names that share one file
  /// (hard links) are one copy and go together. Copies that cannot be
  /// deleted (busy, changed, ownership unknown) are kept and reported.
  void dismiss(String path, List<String> confirmed) {
    _requireIdle(path);
    final chosen = copiesOf(path)
        .where((c) => confirmed.contains(c.staged))
        .toList();
    if (chosen.isEmpty) {
      throw const FileSystemException(
        'Its recovery copies changed. Look again before dismissing.',
      );
    }
    final groups = _byFile(chosen);
    final kept = <String>[];
    for (final group in groups) {
      try {
        _remove(group, path);
      } on FileSystemException catch (error) {
        kept.add(_message(error));
      }
    }
    _settle(path);
    if (kept.isNotEmpty) {
      throw FileSystemException(
        '${kept.length} of ${groups.length} ${groups.length == 1 ? 'copy was' : 'copies were'} kept: ${kept.toSet().join('; ')}',
      );
    }
  }

  /// Copies grouped by file: names with the same identity together; a name
  /// whose file is absent stands alone.
  static List<List<RecoveryCopy>> _byFile(List<RecoveryCopy> copies) {
    final groups = <String, List<RecoveryCopy>>{};
    for (final c in copies) {
      groups
          .putIfAbsent(c.info?.identity ?? 'absent:${c.staged}', () => [])
          .add(c);
    }
    return groups.values.toList();
  }

  /// Removes one copy of [row]: all of [names], the staging names of one
  /// file (hard links). Each name is re-stated just before the guard; one
  /// guard leases the file with its current link count, the bytes are
  /// hashed once (with [expectedHash], kept unless they match), durable
  /// intent is recorded on every name, every name is unlinked under that
  /// same guard, then each name's references go in one transaction. A name
  /// already absent only loses its references; a name another row also
  /// lists loses only this row's reference and its bytes stay.
  void _remove(List<RecoveryCopy> names, String row, {String? expectedHash}) {
    final present = <(RecoveryCopy, NativeFileInfo)>[];
    for (final c in names) {
      if (p.dirname(c.staged) != tree.staging.path) {
        // Never this profile's private staging: not ours to judge or delete.
        throw const FileSystemException(
          'The copy is outside this device\'s staging folder; it is kept.',
        );
      }
      if (_sharedElsewhere(c.staged, row)) {
        _unreference(c.staged, row);
        continue;
      }
      // Fresh: unlinking another name of this file changed its link count.
      // Any stat failure other than "absent" propagates; the copy is kept.
      final info = _info(c.name);
      if (info == null) {
        _finalize(c.staged, c.record);
        continue;
      }
      if (!_ownedNow(c.record, info)) {
        throw const FileSystemException(
          'Ownership of the copy is uncertain; it is kept.',
        );
      }
      present.add((c, info));
    }
    if (present.isEmpty) return;
    final identity = present.first.$2.identity;
    if (present.any((n) => n.$2.identity != identity)) {
      throw const FileSystemException('The copy changed; it is kept.');
    }
    final records = [for (final n in present) n.$1.record!];
    for (final record in records) {
      record.data['dismissing'] = true;
    }
    manifest.save();
    barrier?.call('dismiss-before-unlink', records.first);
    final native = artifacts.native;
    final lead = present.first;
    final int fd;
    try {
      fd = native.guard(
        tree.stageFd,
        lead.$1.name,
        lead.$2,
        links: lead.$2.links,
      );
    } on FileSystemException {
      _clearIntents(records);
      throw const FileSystemException(
        'The copy is open in another program or changed; it is kept.',
      );
    }
    final unlinked = <RecoveryCopy>[];
    try {
      if (expectedHash != null &&
          native.hash(fd, purpose: 'recover-verify') != expectedHash) {
        throw const FileSystemException(
          'The copy no longer matches the restored file; it is kept.',
        );
      }
      for (final (c, _) in present) {
        native.valid(fd);
        native.unlink(fd, tree.stageFd, c.name);
        unlinked.add(c);
      }
    } on FileSystemException catch (error) {
      // Names already unlinked keep their intent and are finalized below;
      // the rest keep the copy and lose the intent.
      _clearIntents([
        for (final (c, _) in present)
          if (!unlinked.contains(c)) c.record!,
      ]);
      for (final c in unlinked) {
        _finalize(c.staged, c.record);
      }
      if (error.message.startsWith('The copy')) rethrow;
      throw const FileSystemException(
        'The copy is open in another program or changed; it is kept.',
      );
    } finally {
      native.close(fd);
    }
    barrier?.call('dismiss-after-unlink-before-db', records.first);
    for (final c in unlinked) {
      _finalize(c.staged, c.record);
    }
  }

  bool _ownedNow(Operation? record, NativeFileInfo info) =>
      record != null &&
      record.phase == 'complete' &&
      record.data['identity'] == info.identity &&
      record.data['directoryIdentity'] == tree.native.identity(tree.stageFd);

  void _clearIntents(List<Operation> records) {
    var changed = false;
    for (final record in records) {
      if (record.data.remove('dismissing') != null) changed = true;
    }
    if (changed) manifest.save();
  }

  void _clearIntent(Operation record) {
    if (record.data.remove('dismissing') != null) manifest.save();
  }

  /// One transaction: only [row]'s references to [staged].
  void _unreference(String staged, String row) {
    manifest.operations.removeWhere(
      (_, o) => o.kind == 'retained' && o.staged == staged && o.path == row,
    );
    manifest.entries[row]?.preservedCopies.remove(staged);
    manifest.save();
  }

  /// One transaction: the record, any `retained` operation and every
  /// preserved-copy reference to [staged] (its bytes are gone).
  void _finalize(String staged, Operation? record) {
    if (record != null) manifest.operations.remove(record.id);
    manifest.operations.removeWhere(
      (_, o) => o.kind == 'retained' && o.staged == staged,
    );
    for (final entry in manifest.entries.values) {
      if (entry.preservedCopies.contains(staged)) {
        entry.preservedCopies.remove(staged);
      }
    }
    manifest.save();
  }

  /// With no copy left, a conflict that only described the copy ends: a
  /// completed deletion stays completed (its row disappears); a present
  /// file is read again by the next pass; a cloud-only file is cloud-only.
  void _settle(String path) {
    final entry = manifest.entries[path];
    if (entry == null) return;
    final remaining = copiesOf(path).where((c) => c.retained);
    if (remaining.isNotEmpty ||
        entry.remoteCopy != null ||
        !copyOnlyConflicts.contains(entry.conflict)) {
      return;
    }
    entry.conflict = null;
    if (!_terminalStatuses.contains(entry.status)) {
      if (entry.expectedPresent) {
        entry.refreshRemote = true;
        entry.status = 'queued';
      } else {
        entry.status = entry.etag != null ? 'cloud-only' : 'removed locally';
      }
    }
    manifest.save();
    restored(path);
  }

  // ---------------------------------------------------------------- Recover

  /// The newest copy: retained copies first, then by modification time.
  RecoveryCopy? newest(String path) {
    final owned = copiesOf(path).where(_owned).toList()
      ..sort((a, b) {
        if (a.retained != b.retained) return a.retained ? -1 : 1;
        return b.info!.modifiedMs.compareTo(a.info!.modifiedMs);
      });
    return owned.firstOrNull;
  }

  /// Restores the newest copy of [path] and returns where it went.
  Map<String, Object?> recover(String path) {
    _requireIdle(path);
    final source = newest(path);
    if (source == null) {
      throw const FileSystemException('No recovery copy here can be restored.');
    }
    return _restore(path, source, destination(path));
  }

  /// The crash-safe write of spec #25: [source] is copied into a recorded
  /// staging file, fsynced and read back, then renamed to [destination]
  /// without replacing anything. The copy is released only once the file
  /// there reads back with the same hash. [trash] names the device-trash
  /// record (spec #44) whose copy this is.
  Map<String, Object?> _restore(
    String path,
    RecoveryCopy source,
    String destination, {
    String? trash,
  }) {
    final temp = artifacts.reserve(path, 'recover-temp');
    final tempRecord = artifacts.record(temp)!;
    final op =
        Operation(
            uniqueId(),
            'recover',
            path,
            staged: tree.durablePath(temp),
            phase: 'writing',
          )
          ..data = {
            'source': source.staged,
            'destination': destination,
            'name': tempRecord.data['name'],
            'trash': ?trash,
          };
    manifest.operations[op.id] = op;
    manifest.save();
    try {
      final hash = copy(source.name, temp);
      // Read back what reached the disk (flushSync is fsync on Linux).
      final written = tree.native.copyAndHash(
        tree.stageFd,
        tempRecord.data['name'] as String,
        null,
        purpose: 'recover-verify',
      );
      if (written != hash) {
        throw const FileSystemException('The restored bytes did not verify.');
      }
      artifacts.complete(temp, hash: hash);
      op.hash = hash;
      op.data['identity'] = tempRecord.data['identity'];
      op.phase = 'written';
      manifest.save();
      barrier?.call('recover-before-rename', op);
      tree.native.checkRoot(tree.fd, tree.root.path);
      // Never recreates a folder: a parent that vanished since [destination]
      // was chosen fails the rename (ENOENT) and the copy is kept.
      rename(destination, tempRecord.data['name'] as String);
    } on FileSystemException catch (error) {
      if (!_renamed(op, destination)) {
        _abandon(op);
        throw FileSystemException(
          '${error.osError?.errorCode == 17 ? 'Something appeared at $destination.' : _message(error)} The recovery copy is kept.',
          error.path ?? '',
          error.osError,
        );
      }
      // The file is in place but the disk did not confirm it durable (a
      // failed fsync after the rename): report it restored, keep the copy.
      op.data['unconfirmed'] = true;
      manifest.save();
    }
    barrier?.call('recover-after-rename-before-db', op);
    tree.own(destination);
    restored(destination);
    final unconfirmed = op.data['unconfirmed'] == true;
    final kept = _finish(op, release: !unconfirmed);
    return {
      'path': path,
      'destination': destination,
      'kept': kept,
      if (unconfirmed) 'unconfirmed': true,
    };
  }

  /// The rename happened: the temporary name is gone from staging and the
  /// destination is the file this Recover wrote.
  bool _renamed(Operation op, String destination) {
    try {
      if (_info(op.data['name'] as String) != null) return false;
      return artifacts.native.info(tree.fd, destination).identity ==
          op.data['identity'];
    } on FileSystemException {
      return false;
    }
  }

  /// Whether [path] is free: nothing on disk, no live entry or pending
  /// work, no tracked descendants and no other Recover heading there.
  bool free(String path, {required String row}) {
    if (isSyncExcluded(path)) return false;
    if (manifest.operations.values.any(
      (o) => o.kind == 'recover' && o.data['destination'] == path,
    )) {
      return false;
    }
    bool live(Entry e) =>
        e.etag != null ||
        e.expectedPresent ||
        (e.conflict != null && e.path != row) ||
        manifest.operationsAt(e.path).any((o) => !_passive.contains(o.kind));
    final entry = manifest.entries[path];
    if (entry != null && live(entry)) return false;
    if (manifest.entries.values.any(
      (e) => p.posix.isWithin(path, e.path) && live(e),
    )) {
      return false;
    }
    try {
      return tree.statItem(path) == null;
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return true;
      return false;
    }
  }

  /// Whether [path]'s parent folder still exists: on disk as a directory,
  /// and not a deletion the manifest has recorded or queued.
  bool parentExists(String path) {
    final parent = p.posix.dirname(path);
    if (parent == '.') return true;
    // A folder deleted, or whose deletion (or an ancestor's) is still
    // pending, counts as gone.
    var folder = parent;
    while (folder != '.') {
      final entry = manifest.entries[folder];
      if (entry != null && _terminalStatuses.contains(entry.status)) {
        return false;
      }
      if (manifest.operationsAt(folder).any((o) => o.kind == 'delete')) {
        return false;
      }
      folder = p.posix.dirname(folder);
    }
    try {
      return tree.statItem(parent)?.kind == ItemKind.directory;
    } on FileSystemException {
      return false;
    }
  }

  /// The original path when free, else `name (recovered).ext`, then
  /// `name (recovered 2).ext` and so on. When the original folder no longer
  /// exists, the same rule applies at the top level of the sync folder: a
  /// deleted folder is never recreated (spec #25 ruling).
  String destination(String row) {
    final path = parentExists(row) ? row : p.posix.basename(row);
    if (free(path, row: row)) return path;
    final directory = p.posix.dirname(path);
    final base = p.posix.basenameWithoutExtension(path);
    final extension = p.posix.extension(path);
    for (var n = 1; n < 10000; n++) {
      final name = '$base (recovered${n == 1 ? '' : ' $n'})$extension';
      final candidate = directory == '.' ? name : '$directory/$name';
      if (free(candidate, row: row)) return candidate;
    }
    throw const FileSystemException('No free name to recover to.');
  }

  /// Before the rename: the temporary file is deleted and the intent ends;
  /// the copy is untouched.
  void _abandon(Operation op) {
    final record = artifacts.record(File(op.staged!));
    final name = op.data['name'] as String;
    final info = _info(name);
    if (info != null) {
      if (record?.data['identity'] != null &&
          record!.data['identity'] != info.identity) {
        // Not the file this intent wrote: leave it, recorded, for review.
        manifest.operations.remove(op.id);
        manifest.save();
        return;
      }
      final fd = artifacts.native.guard(
        tree.stageFd,
        name,
        info,
        links: info.links,
      );
      try {
        artifacts.native.unlink(fd, tree.stageFd, name);
      } finally {
        artifacts.native.close(fd);
      }
    }
    if (record != null) manifest.operations.remove(record.id);
    manifest.operations.remove(op.id);
    manifest.save();
  }

  /// After the rename: the restored file is verified in the root, then the
  /// source copy (and its aliases) released under a hash-checked guard.
  /// Returns true when the copy was kept.
  bool _finish(Operation op, {bool release = true}) {
    final destination = op.data['destination'] as String;
    final row = op.path;
    final tempRecord = artifacts.record(File(op.staged!));
    var verified = false;
    try {
      final info = artifacts.native.info(tree.fd, destination);
      verified =
          info.identity == op.data['identity'] &&
          tree.native.copyAndHash(
                tree.fd,
                destination,
                null,
                purpose: 'recover-verify',
              ) ==
              op.hash;
    } on FileSystemException {
      verified = false;
    }
    var kept = true;
    final trash = op.data['trash'];
    if (verified && release && trash is String) {
      // A device-trash copy (spec #44): every name of its file goes, then
      // the trash record.
      final names = trashCopies(manifest.operations[trash]);
      if (names.isNotEmpty && names.every((c) => c.info == null || _owned(c))) {
        try {
          _remove(names, row, expectedHash: op.hash);
          manifest.operations.remove(trash);
          kept = false;
        } on FileSystemException {
          kept = true;
        }
      } else if (names.isEmpty) {
        manifest.operations.remove(trash);
      }
    } else if (verified && release) {
      final source = op.data['source'] as String;
      final copies = copiesOf(row);
      final copy = copies.where((c) => c.staged == source).firstOrNull;
      if (copy != null && _owned(copy)) {
        final aliases = copies.where(
          (c) =>
              c.staged != source &&
              _owned(c) &&
              c.info!.identity == copy.info!.identity,
        );
        try {
          // One file, all its names: verified once, released together.
          _remove([copy, ...aliases], row, expectedHash: op.hash);
          kept = false;
        } on FileSystemException {
          kept = true;
        }
      }
    }
    if (tempRecord != null) manifest.operations.remove(tempRecord.id);
    manifest.operations.remove(op.id);
    manifest.save();
    _settle(row);
    return kept;
  }

  // ----------------------------------------------------------- Device trash

  /// The names of a device-trash record's file (spec #44) as they stand now:
  /// its owning records and present files. Empty for anything else.
  List<RecoveryCopy> trashCopies(Operation? trash) {
    if (trash == null || trash.kind != 'trash') return const [];
    final names = <String>{
      ?trash.staged,
      ...(trash.data['names'] as List? ?? const []).cast<String>(),
    };
    final byStaged = {
      for (final record in artifacts.records)
        if (record.staged != null) record.staged!: record,
    };
    return [
      for (final staged in names)
        RecoveryCopy(
          staged,
          byStaged[staged],
          _present(p.basename(staged)),
          retained: true,
        ),
    ];
  }

  NativeFileInfo? _present(String name) {
    try {
      return _info(name);
    } on FileSystemException {
      return null;
    }
  }

  /// Whether this profile owns [copy] (its record matches the file).
  bool owned(RecoveryCopy copy) => _owned(copy);

  /// Copies grouped by file: hard-linked names together.
  static List<List<RecoveryCopy>> byFile(List<RecoveryCopy> copies) =>
      _byFile(copies);

  /// Drops every reference to [staged], whose bytes are gone or now belong
  /// to a device-trash record.
  void forget(String staged, Operation? record) => _finalize(staged, record);

  /// Deletes one file's names under the guard (Dismiss's primitive).
  void removeNames(List<RecoveryCopy> names, String row) => _remove(names, row);

  /// [removeNames], only when the bytes still hash to [expectedHash].
  void removeNamesVerified(
    List<RecoveryCopy> names,
    String row,
    String expectedHash,
  ) => _remove(names, row, expectedHash: expectedHash);

  /// Restores a device-trash copy (spec #44) to [destination] with the
  /// crash-safe write; the record goes once the restored file verifies.
  Map<String, Object?> restoreTrash(Operation trash, String destination) {
    final names = trashCopies(trash).where(_owned).toList();
    if (names.isEmpty) {
      throw const FileSystemException('This copy can no longer be restored.');
    }
    return _restore(trash.path, names.first, destination, trash: trash.id);
  }

  /// [row] when nothing holds it, else `name (restored).ext`, then
  /// `name (restored 2).ext` and so on, in the same folder (spec #44).
  String trashDestination(String row) {
    if (free(row, row: row)) return row;
    final directory = p.posix.dirname(row);
    final base = p.posix.basenameWithoutExtension(row);
    final extension = p.posix.extension(row);
    for (var n = 1; n < 10000; n++) {
      final name = '$base (restored${n == 1 ? '' : ' $n'})$extension';
      final candidate = directory == '.' ? name : '$directory/$name';
      if (free(candidate, row: row)) return candidate;
    }
    throw const FileSystemException('No free name to restore to.');
  }

  // ---------------------------------------------------------------- Crashes

  /// Converges actions a crash interrupted. Dismiss: a copy whose bytes are
  /// gone loses its references; one still present keeps them and its
  /// intent is cleared. Recover before the rename: the temporary file is
  /// deleted. After it: the restored file is verified and the copy released
  /// exactly as an uninterrupted Recover would.
  void recoverInterrupted() {
    final stage = tree.native.identity(tree.stageFd);
    for (final record in artifacts.records.toList()) {
      if (record.data['dismissing'] != true) continue;
      if (record.data['directoryIdentity'] != stage) continue;
      final info = _info(record.data['name'] as String);
      if (info == null) {
        _finalize(record.staged!, record);
      } else {
        _clearIntent(record);
      }
    }
    for (final op
        in manifest.operations.values
            .where((o) => o.kind == 'recover')
            .toList()) {
      final name = op.data['name'] as String;
      final record = artifacts.record(File(op.staged!));
      final info = _info(name);
      final renamed =
          op.phase == 'written' &&
          info == null &&
          record?.data['identity'] != null;
      if (renamed) {
        _finish(op, release: op.data['unconfirmed'] != true);
      } else {
        try {
          _abandon(op);
        } on FileSystemException {
          // Busy: the next pass retries; the copy is untouched either way.
        }
      }
    }
    // A temporary file reserved just before its intent was written.
    for (final record in artifacts.records.toList()) {
      if (record.data['role'] != 'recover-temp' ||
          manifest.operations.values.any(
            (o) => o.kind == 'recover' && o.staged == record.staged,
          )) {
        continue;
      }
      final info = _info(record.data['name'] as String);
      if (info == null) {
        manifest.operations.remove(record.id);
        manifest.save();
      } else if (info.identity == record.data['identity']) {
        final fd = artifacts.native.guard(
          tree.stageFd,
          record.data['name'] as String,
          info,
          links: info.links,
        );
        try {
          artifacts.native.unlink(
            fd,
            tree.stageFd,
            record.data['name'] as String,
          );
        } finally {
          artifacts.native.close(fd);
        }
        manifest.operations.remove(record.id);
        manifest.save();
      }
    }
  }
}
