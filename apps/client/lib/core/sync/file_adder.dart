import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../local/root_tree.dart';
import '../ports/documents_filesystem.dart';
import '../state/model.dart';
import 'name_policy.dart';
import 'name_rule.dart';
import 'sync_engine.dart';
import 'sync_path_policy.dart';

/// Why an item of an add was not added (spec #43 Copy Rules, Summary).
enum AddSkip {
  overLimit,
  blockedName,
  excluded,
  unreadable,
  noStream,
  cancelled,
  failed;

  static AddSkip? byCode(Object? code) => switch (code) {
    'overLimit' => overLimit,
    'blocked' || 'blockedName' => blockedName,
    'excluded' => excluded,
    'unreadable' => unreadable,
    'noStream' => noStream,
    'cancelled' => cancelled,
    _ => null,
  };

  /// The reason in plain words; [limit] is the upload limit in bytes.
  String text(int limit) => switch (this) {
    overLimit => 'Larger than the ${sizeLabel(limit)} upload limit',
    blockedName => "Can't sync this name",
    excluded => 'Not synchronized by AnJ Cloud',
    unreadable => 'Could not read this file',
    noStream => 'Not a file that can be copied',
    cancelled => 'Cancelled',
    failed => 'Could not be added',
  };
}

/// Space kept free on the phone beyond what an add needs (spec #43).
const addFreeSpaceReserve = 256 * 1024 * 1024;

/// The worker's side of Add files, Add folder and the Share sheet (spec #43
/// A3): each picked item is copied into the root through the
/// descriptor-relative boundary and reconciled by the next pass like any new
/// local file. Platform-neutral: a source is any path the worker can read.
///
/// - **Copy, never move**: the source is only read.
/// - **Exclusive create**: a folder is an exclusive mkdir; a file is written
///   into private staging (outside the watched root, owned by a manifest
///   record from before it exists), flushed, then renamed into place without
///   replacing anything. A failed, cancelled or interrupted copy therefore
///   never leaves a file in the root, and a pass never sees a partial one;
///   [sweep] removes a staged leftover at the next start.
/// - **Names**: the top item of an add is numbered `name (2).ext`, `(3)`
///   when its name (or one differing only by case or Unicode normalization)
///   is taken; a name other devices cannot hold is refused (decision #120),
///   an excluded name is skipped.
class FileAdder {
  FileAdder(this.engine, {this.paused, this.openSource});
  final SyncEngine engine;
  final bool Function()? paused;

  /// Reads a source; the file at that path unless a test supplies another.
  final Stream<List<int>> Function(String source)? openSource;

  /// Runs the user cancelled; checked between chunks of a copy.
  final _cancelled = <String>{};

  /// Staging role of a copy in progress.
  static const stagingRole = 'add';

  RootTree get tree => engine.tree;

  int get uploadLimit => engine.cloud.uploadLimit ?? assumedUploadLimit;

  void cancel(String run) => _cancelled.add(run);

  /// The run is over: forget its cancel mark.
  void finished(String run) => _cancelled.remove(run);

  static String _join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  static String _parentOf(String path) {
    final parent = p.posix.dirname(path);
    return parent == '.' ? '' : parent;
  }

  void _notPaused() {
    if (paused?.call() ?? false) {
      throw const DocumentsFailure('paused', 'Sync is paused');
    }
  }

  /// A row of a completed deletion: its name is free again.
  static bool _deletedRow(Entry entry) =>
      entry.etag == null &&
      !entry.expectedPresent &&
      const {
        'deleted',
        'deleted remotely',
        'removed locally',
      }.contains(entry.status);

  /// Names beside [parent], locally and in the cloud. A name deleted
  /// everywhere is free.
  Set<String> _siblings(String parent) => {
    for (final key in {
      ...tree.scanItems(includeExcluded: true).keys,
      for (final entry in engine.manifest.entries.values)
        if (!_deletedRow(entry)) entry.path,
      for (final op in engine.manifest.operations.values)
        if (op.kind != 'artifact') op.path,
    })
      if (_parentOf(key) == parent) p.posix.basename(key),
  };

  static bool _pendingDelete(SyncEngine engine, String path) =>
      engine.manifest.operations.values.any(
        (op) =>
            op.kind == 'delete' &&
            (op.path == path || p.posix.isWithin(op.path, path)),
      );

  /// Spec #43 Eligible Destinations (decision #190), the one test the
  /// library projection (`canReceiveFiles`) and the worker share: a real
  /// folder without a conflict, not excluded, not View only, with no pending
  /// deletion on it or above it, that is either on this device or a synced
  /// Cloud-only folder (a recorded cloud version, not a held #120 name) whose
  /// missing parents pass the same test.
  static bool canReceive(SyncEngine engine, String path) {
    if (path.isEmpty || isSyncExcluded(path)) return false;
    final entry = engine.manifest.entries[path];
    if (entry == null ||
        entry.kind != ItemKind.directory ||
        entry.conflict != null ||
        engine.viewOnly(path) ||
        _pendingDelete(engine, path)) {
      return false;
    }
    for (var current = path; current.isNotEmpty; current = _parentOf(current)) {
      final row = engine.manifest.entries[current];
      if (row == null ||
          row.kind != ItemKind.directory ||
          row.conflict != null ||
          row.status.startsWith('deleted')) {
        return false;
      }
      // On this device: nothing above it needs creating.
      if (row.expectedPresent && engine.localDirectories.contains(current)) {
        return true;
      }
      if (row.etag == null) return false;
    }
    return true;
  }

  /// [folder] can receive items: a directory here, or a synced Cloud-only
  /// folder ([canReceive]), which [create] makes on this device first (the
  /// pass then uploads and releases what is added; the folder stays). A
  /// folder this add just made has no manifest entry until the next pass and
  /// still qualifies.
  void _writableFolder(String folder, {bool create = true}) {
    if (folder.isNotEmpty) {
      validateRelative(folder);
      final entry = engine.manifest.entries[folder];
      final here = tree.statItem(folder)?.kind == ItemKind.directory;
      if ((!here && !canReceive(engine, folder)) ||
          (entry != null &&
              (entry.kind != ItemKind.directory || entry.conflict != null)) ||
          isSyncExcluded(folder)) {
        throw const DocumentsFailure(
          'notFound',
          'The folder is not available on this device',
        );
      }
      if (!here && create) _materialize(folder);
    }
    if (engine.viewOnly(folder)) {
      throw const DocumentsFailure('readOnly', 'View-only share');
    }
    if (_pendingDelete(engine, folder)) {
      throw const DocumentsFailure('refused', 'The folder is being deleted');
    }
  }

  /// Creates the Cloud-only [folder] (and missing parents) on this device,
  /// the way downloads and moves do.
  void _materialize(String folder) {
    tree.ensureDirectory(folder);
    for (
      var current = folder;
      current.isNotEmpty;
      current = _parentOf(current)
    ) {
      engine.localDirectories.add(current);
    }
    engine.markDirty(folder);
  }

  /// Whether [name] is used in [taken], exactly or apart from case or
  /// Unicode normalization (the #120 sibling rule).
  static bool _taken(String name, Set<String> taken, Set<String> keys) =>
      taken.contains(name) || keys.contains(NamePolicy.foldKey(name));

  /// [name], else the first free `stem (n).ext` from 2 on, the numbering of
  /// the gateway's fetch import.
  static String freeName(
    String name,
    Iterable<String> taken, {
    required bool directory,
  }) {
    final names = taken.toSet();
    final keys = {for (final n in names) NamePolicy.foldKey(n)};
    if (!_taken(name, names, keys)) return name;
    final extension = directory ? '' : p.posix.extension(name);
    final stem = name.substring(0, name.length - extension.length);
    for (var n = 2; ; n++) {
      final candidate = '$stem ($n)$extension';
      if (!_taken(candidate, names, keys)) return candidate;
    }
  }

  /// The skip of a name before any numbering, or null.
  static AddSkip? nameSkip(
    String parent,
    String name, {
    required bool directory,
  }) {
    // Spec #49: only a name R2 cannot fix (or a file that would only ever be
    // a quiet local temporary); every other name is cleaned by the pass.
    if (renameRefusal(name, folder: directory) != null) {
      return AddSkip.blockedName;
    }
    if (isSyncExcluded(_join(parent, name))) return AddSkip.excluded;
    return null;
  }

  // ---- before copying ------------------------------------------------------

  /// Evaluates a selection before anything is written (spec #43 Before
  /// Copying). [items] are `{path, directory, size, virtual}`, where `path`
  /// is relative to the selection ('a.txt', 'Tree/sub/b.txt'), parents
  /// before children. [free] is the free space of the root's volume.
  Map<String, Object?> check(String destination, List<Map> items, {int? free}) {
    if (destination.isNotEmpty) validateRelative(destination);
    // Nothing is created before the user confirms.
    _writableFolder(destination, create: false);
    return plan(
      items,
      siblings: _siblings(destination),
      destination: destination,
      limit: uploadLimit,
      free: free,
    );
  }

  /// [check] without the root: the verdict for each item, in order.
  static Map<String, Object?> plan(
    List<Map> items, {
    required Set<String> siblings,
    String destination = '',
    required int limit,
    int? free,
  }) {
    final taken = {...siblings};
    // Selection-relative folder -> its verdict, for the subtree rule.
    final folders = <String, AddSkip?>{};
    final verdicts = <Map<String, Object?>>[];
    var files = 0, folderCount = 0, bytes = 0;
    for (final item in items) {
      final path = item['path'] as String;
      final directory = item['directory'] == true;
      final size = item['size'] as int?;
      final parent = _parentOf(path);
      final name = p.posix.basename(path);
      final top = parent.isEmpty;
      AddSkip? skip;
      String? target;
      var listed = true;
      if (!top && !folders.containsKey(parent)) {
        skip = AddSkip.failed;
      } else if (!top && folders[parent] != null) {
        // A refused or skipped folder skips its whole subtree, listed once.
        skip = folders[parent];
        listed = false;
      } else {
        skip = nameSkip(
          top ? destination : _join(destination, parent),
          name,
          directory: directory,
        );
        if (skip == null && !directory) {
          if (item['virtual'] == true) {
            skip = AddSkip.noStream;
          } else if (size != null && size > limit) {
            skip = AddSkip.overLimit;
          }
        }
        if (skip == null) {
          target = top ? freeName(name, taken, directory: directory) : name;
          if (top) taken.add(target);
          if (directory) {
            folderCount++;
          } else {
            files++;
            bytes += size ?? 0;
          }
        }
      }
      if (directory) folders[path] = skip;
      verdicts.add({
        'path': path,
        'directory': directory,
        'size': ?size,
        'target': ?target,
        'renamed': target != null && target != name,
        'skip': skip?.name,
        'listed': listed,
      });
    }
    final room = free == null ? null : free - addFreeSpaceReserve;
    return {
      'items': verdicts,
      'files': files,
      'folders': folderCount,
      'bytes': bytes,
      'limit': limit,
      'free': free,
      'noSpace': room != null && bytes > room,
    };
  }

  // ---- copying -------------------------------------------------------------

  /// The root path for [name] in [parent]: numbered when [number] (the top
  /// item of an add), otherwise exactly [name].
  String _target(String parent, String name, {required bool number}) {
    _notPaused();
    _writableFolder(parent);
    final siblings = _siblings(parent);
    final skip = nameSkip(parent, name, directory: false);
    if (skip != null) throw DocumentsFailure(skip.name, skip.text(uploadLimit));
    final chosen = number ? freeName(name, siblings, directory: false) : name;
    if (!number && siblings.contains(name)) {
      throw const DocumentsFailure('exists', 'This name is already used');
    }
    final target = _join(parent, chosen);
    validateRelative(target);
    return target;
  }

  /// Creates folder [name] in [parent] (an exclusive mkdir, reconciled by
  /// the next pass with its parent's storage choice). Returns its path.
  String addFolder(String parent, String name, {required bool number}) {
    for (var attempt = 0; ; attempt++) {
      final siblings = _siblings(parent);
      _notPaused();
      _writableFolder(parent);
      final skip = nameSkip(parent, name, directory: true);
      if (skip != null) {
        throw DocumentsFailure(skip.name, skip.text(uploadLimit));
      }
      if (!number && siblings.contains(name)) {
        throw const DocumentsFailure('exists', 'This name is already used');
      }
      final target = _join(
        parent,
        number ? freeName(name, siblings, directory: true) : name,
      );
      validateRelative(target);
      tree.native.checkRoot(tree.fd, tree.root.path);
      try {
        tree.native.makeDirExclusive(tree.fd, target);
      } on FileSystemException catch (error) {
        // Taken meanwhile: a numbered name tries the next number.
        if (error.osError?.errorCode == 17 && number && attempt < 8) continue;
        if (error.osError?.errorCode == 17) {
          throw const DocumentsFailure('exists', 'This name is already used');
        }
        rethrow;
      }
      engine.markDirty(target);
      engine.message = 'Added. Synchronization is queued.';
      return target;
    }
  }

  /// Copies the file at [source] to [name] in [parent]. The bytes go to
  /// private staging first; only a complete, flushed copy is renamed into
  /// the root, never replacing a name. Returns the new path. Fails with a
  /// [DocumentsFailure] whose code is an [AddSkip] name when the item is
  /// skipped; nothing of it is then left in the root or in staging.
  Future<String> addFile(
    String parent,
    String name,
    String source, {
    required bool number,
    String run = '',
  }) async {
    final limit = uploadLimit;
    _target(parent, name, number: number); // refuses before any byte
    if (openSource == null) {
      final int length;
      try {
        length = File(source).lengthSync();
      } on FileSystemException {
        throw DocumentsFailure('unreadable', AddSkip.unreadable.text(limit));
      }
      if (length > limit) {
        throw DocumentsFailure('overLimit', AddSkip.overLimit.text(limit));
      }
    }
    final artifacts = engine.artifacts;
    final staged = artifacts.reserve(_join(parent, name), stagingRole);
    final op = artifacts.record(staged)!;
    final stagedName = p.basename(staged.path);
    var installed = false;
    try {
      await _copy(source, staged, limit, run);
      for (var attempt = 0; ; attempt++) {
        final target = _target(parent, name, number: number);
        tree.native.checkRoot(tree.fd, tree.root.path);
        tree.native.checkRoot(tree.stageFd, tree.staging.path);
        try {
          // A no-replace rename; both directories are flushed.
          artifacts.native.restore(tree.fd, target, tree.stageFd, stagedName);
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode == 17 && number && attempt < 8) continue;
          if (error.osError?.errorCode == 17) {
            throw const DocumentsFailure('exists', 'This name is already used');
          }
          rethrow;
        }
        installed = true;
        engine.manifest.operations.remove(op.id);
        engine.manifest.save();
        engine.markDirty(target);
        engine.message = 'Added. Synchronization is queued.';
        return target;
      }
    } finally {
      if (!installed) _discard(op.id, stagedName);
    }
  }

  Future<void> _copy(String source, File staged, int limit, String run) async {
    final output = staged.openSync(mode: FileMode.writeOnly);
    var written = 0;
    try {
      final Stream<List<int>> stream;
      try {
        stream = openSource?.call(source) ?? File(source).openRead();
      } on FileSystemException {
        throw DocumentsFailure('unreadable', AddSkip.unreadable.text(limit));
      }
      try {
        await for (final chunk in stream) {
          if (_cancelled.contains(run)) {
            throw DocumentsFailure('cancelled', AddSkip.cancelled.text(limit));
          }
          written += chunk.length;
          if (written > limit) {
            throw DocumentsFailure('overLimit', AddSkip.overLimit.text(limit));
          }
          output.writeFromSync(chunk);
        }
      } on FileSystemException {
        throw DocumentsFailure('unreadable', AddSkip.unreadable.text(limit));
      }
      if (_cancelled.contains(run)) {
        throw DocumentsFailure('cancelled', AddSkip.cancelled.text(limit));
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
  }

  /// Removes a staged copy that was never installed, and its record.
  void _discard(String id, String name) {
    try {
      tree.stagedFile(p.join(tree.staging.path, name)).deleteSync();
    } on FileSystemException {
      // Already gone, or left for [sweep] at the next start.
    }
    engine.manifest.operations.remove(id);
    engine.manifest.save();
  }

  /// At start (spec #43 Interruption): a copy the process did not finish is
  /// removed from staging with its record. It never reached the root.
  static List<String> sweep(SyncEngine engine) {
    final tree = engine.tree;
    final removed = <String>[];
    final leftovers = engine.artifacts.records
        .where((o) => o.data['role'] == stagingRole)
        .toList();
    for (final op in leftovers) {
      final name = op.data['name'] as String;
      try {
        tree.stagedFile(p.join(tree.staging.path, name)).deleteSync();
        removed.add(name);
      } on FileSystemException {
        // Never created, or already gone.
      }
      engine.manifest.operations.remove(op.id);
    }
    if (leftovers.isNotEmpty) engine.manifest.save();
    return removed;
  }
}
