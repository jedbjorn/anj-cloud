import 'dart:io';

import 'package:path/path.dart' as p;

import '../gateway/sharing.dart';
import '../local/root_tree.dart';
import '../ports/documents_filesystem.dart';
import '../state/model.dart';
import 'name_policy.dart';
import 'open_documents.dart';
import 'sync_engine.dart';
import 'sync_path_policy.dart';
import 'top_folders.dart';

/// The sync worker's side of the documents provider (spec #28 A5): each
/// provider change is an engine command through the descriptor-relative
/// boundary, reconciled by the next pass like any local change.
///
/// - **open**: a Local file is a descriptor on the root file; a Cloud-only
///   file is downloaded into a private editor working copy (as the Open
///   action does, #16) and that copy's descriptor is returned. Every
///   descriptor is entered in [OpenDocuments] until the app closes it, and a
///   written one marks the file for the next pass (conditional upload).
/// - **create**: an exclusive mkdir or file create (never replacing a
///   name), reconciled by the next pass.
/// - **rename / move**: a no-replace rename in the root. An item that was
///   ever synchronized is also given a deletion intent at its old path, so
///   the pass uploads the new path and deletes the old one (not optimized,
///   spec #3 preservation rules apply). Only items with local bytes move: a
///   Cloud-only file, or a folder holding one, is refused.
/// - **delete**: a synchronized item gets the existing deletion intent
///   (#70); a never-synchronized file is removed under the release guard,
///   an empty never-synchronized folder directly.
///
/// Names follow decision #120: a name other devices cannot hold is refused
/// here, before anything is created, rather than kept local-only.
class DocumentsOps {
  DocumentsOps(this.engine, {OpenDocuments? registry, this.paused})
    : registry = registry ?? openDocuments;
  final SyncEngine engine;
  final OpenDocuments registry;
  final bool Function()? paused;

  RootTree get tree => engine.tree;
  DocumentsFilesystem get _fs {
    final native = tree.native;
    if (native is! DocumentsFilesystem) {
      throw const DocumentsFailure(
        'unavailable',
        'This platform has no documents provider boundary.',
      );
    }
    return native as DocumentsFilesystem;
  }

  bool get _paused => paused?.call() ?? false;

  void _notPaused() {
    if (_paused) {
      throw const DocumentsFailure(
        'paused',
        'Sync is paused. Resume sync in AnJ Cloud to change files here.',
      );
    }
  }

  Future<Map<String, Object?>> handle(String op, Map command) async {
    try {
      engine.requireStorageReady();
    } on CloudFailure catch (error) {
      throw DocumentsFailure('unavailable', error.message);
    }
    switch (op) {
      case 'open':
        return open(
          path: command['path'] as String?,
          working: command['working'] as String?,
          write: command['write'] == true,
          token: command['token'] as String,
        );
      case 'closed':
        closed(command['token'] as String);
        return const {};
      case 'create':
        final parent = command['parent'] as String;
        final name = command['name'] as String;
        return {
          'path': command['directory'] == true
              ? createFolder(parent, name)
              : create(parent, name),
        };
      case 'rename':
        final path = command['path'] as String;
        return {
          'path': relocate(path, _parentOf(path), command['name'] as String),
        };
      case 'move':
        final path = command['path'] as String;
        return {
          'path': relocate(
            path,
            command['parent'] as String,
            p.posix.basename(path),
          ),
        };
      case 'delete':
        delete(command['path'] as String);
        return const {};
    }
    throw DocumentsFailure('refused', 'Unknown documents command $op.');
  }

  static String _parentOf(String path) {
    final parent = p.posix.dirname(path);
    return parent == '.' ? '' : parent;
  }

  static String _join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  // ---- open ----------------------------------------------------------------

  Future<Map<String, Object?>> open({
    String? path,
    String? working,
    required bool write,
    required String token,
  }) async {
    if (working != null) return _openWorking(working, write, token);
    validateRelative(path!);
    final entry = engine.manifest.entries[path];
    if (entry != null && entry.kind != ItemKind.file) {
      throw const DocumentsFailure('notFound', 'Not a file.');
    }
    if (write && engine.viewOnly(path)) {
      throw const DocumentsFailure(
        'readOnly',
        'This file is shared with you as View only.',
      );
    }
    final local = tree.statItem(path);
    if (local != null && local.kind == ItemKind.file) {
      return _hand(tree.fd, path, path, write, token);
    }
    if (entry == null || entry.etag == null) {
      throw const DocumentsFailure('notFound', 'This file is not available.');
    }
    // Cloud-only: the Open action's private editor working copy. One
    // unchanged copy of the current version is reused, so an app that
    // reopens a file does not download it again.
    final reuse = _reusableWorkingCopy(path, entry);
    if (reuse != null) return _openWorking(reuse, write, token);
    if (_paused) {
      throw const DocumentsFailure(
        'paused',
        'Sync is paused. Resume sync in AnJ Cloud to download this file.',
      );
    }
    final String staged;
    try {
      staged = await engine.openFile(path);
    } on CloudFailure catch (error) {
      throw DocumentsFailure('unavailable', error.message);
    }
    return _openWorking(p.basename(staged), write, token);
  }

  String? _reusableWorkingCopy(String path, Entry entry) {
    for (final op in engine.manifest.operationsAt(path)) {
      if (op.kind != 'working' ||
          op.staged == null ||
          op.expectedEtag != entry.etag) {
        continue;
      }
      final file = engine.artifacts.resolve(op.staged!);
      final record = engine.artifacts.record(file);
      final name = p.basename(op.staged!);
      try {
        final now = engine.artifacts.native.info(tree.stageFd, name);
        if (record?.data['stamp'] == now.stamp) return name;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Map<String, Object?> _openWorking(String name, bool write, String token) {
    validateRelative(name);
    final owner = engine.manifest.operations.values.where(
      (op) =>
          op.kind == 'working' &&
          op.staged != null &&
          p.basename(op.staged!) == name,
    );
    if (owner.isEmpty) {
      throw const DocumentsFailure(
        'notFound',
        'This working copy was finished or removed.',
      );
    }
    final path = owner.first.path;
    if (write && engine.viewOnly(path)) {
      throw const DocumentsFailure(
        'readOnly',
        'This file is shared with you as View only.',
      );
    }
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    return _hand(tree.stageFd, name, path, write, token, working: name);
  }

  /// A read-only descriptor of [relative] beneath [directory], recorded in
  /// the registry. The runner reopens it with the app's mode through
  /// /proc/self/fd (same inode) and closes this descriptor.
  Map<String, Object?> _hand(
    int directory,
    String relative,
    String path,
    bool write,
    String token, {
    String? working,
  }) {
    if (directory == tree.fd) tree.native.checkRoot(tree.fd, tree.root.path);
    final fd = _fs.openRead(directory, relative);
    try {
      final info = engine.artifacts.native.infoFd(fd);
      registry.add(
        token,
        OpenDocument(path, info.identity, write: write, working: working),
      );
      return {'fd': fd, 'size': info.size, 'token': token};
    } catch (_) {
      tree.native.closeFd(fd);
      rethrow;
    }
  }

  /// The app closed descriptor [token]: a written file is reconciled by the
  /// next pass (Local: uploaded through the conditional path; a working
  /// copy: kept for Finish editing, #108 Q10).
  void closed(String token) {
    final document = registry.remove(token);
    if (document == null) return;
    if (document.write) engine.markDirty(document.path);
  }

  // ---- names ---------------------------------------------------------------

  /// The names already used beside [parent], locally and in the cloud.
  Set<String> _siblings(String parent) => {
    for (final key in {
      ...tree.scanItems(includeExcluded: true).keys,
      ...engine.manifest.entries.keys,
    })
      if (_parentOf(key) == parent) p.posix.basename(key),
  };

  String _checkName(String parent, String name, Set<String> siblings) {
    if (name.isEmpty ||
        name.contains('/') ||
        name == '.' ||
        name == '..' ||
        name.contains('\x00')) {
      throw const DocumentsFailure(
        'refused',
        'Use one name without path separators.',
      );
    }
    final problem = NamePolicy.problem(name, siblings);
    if (problem != null) throw DocumentsFailure('refused', problem.text);
    final target = _join(parent, name);
    validateRelative(target);
    if (isSyncExcluded(target)) {
      throw const DocumentsFailure(
        'refused',
        'This name is excluded from synchronization. Choose another name.',
      );
    }
    return target;
  }

  /// [folder] can take a new item: a directory under the root, not
  /// excluded and not View only. A folder the provider just made has no
  /// manifest entry until the next pass and still qualifies (review F2);
  /// an entry that says it is something else does not.
  void _writableFolder(String folder) {
    if (folder.isEmpty) return;
    final entry = engine.manifest.entries[folder];
    final local = tree.statItem(folder);
    if (local?.kind != ItemKind.directory ||
        (entry != null && entry.kind != ItemKind.directory) ||
        isSyncExcluded(folder)) {
      throw const DocumentsFailure(
        'notFound',
        'The folder is not available on this device.',
      );
    }
    if (engine.viewOnly(folder)) {
      throw const DocumentsFailure(
        'readOnly',
        'This folder is shared with you as View only.',
      );
    }
  }

  // ---- create --------------------------------------------------------------

  /// The free name for [name] in [parent]: [name] itself, else the first
  /// "name (n).ext" (Android's convention). Nothing is ever replaced.
  String _newTarget(String parent, String name, {required bool directory}) {
    _notPaused();
    if (parent.isNotEmpty) validateRelative(parent);
    _writableFolder(parent);
    final siblings = _siblings(parent);
    var candidate = name;
    final extension = directory ? '' : p.posix.extension(name);
    final stem = name.substring(0, name.length - extension.length);
    for (var n = 1; siblings.contains(candidate); n++) {
      if (n > 64) {
        throw const DocumentsFailure('exists', 'Choose another name.');
      }
      candidate = '$stem ($n)$extension';
    }
    final target = _checkName(parent, candidate, siblings);
    if (engine.manifest.operations.values.any(
      (op) =>
          op.path == target ||
          (op.kind == 'delete' &&
              (op.path == parent || p.posix.isWithin(op.path, target))),
    )) {
      throw const DocumentsFailure(
        'refused',
        'This location has pending changes. Try again after the next sync.',
      );
    }
    return target;
  }

  /// Creates the empty file [name] in [parent] by an exclusive create.
  String create(String parent, String name) {
    final target = _newTarget(parent, name, directory: false);
    tree.native.checkRoot(tree.fd, tree.root.path);
    final int fd;
    try {
      fd = _fs.createExclusive(tree.fd, target);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 17) {
        throw const DocumentsFailure('exists', 'This name is already used.');
      }
      rethrow;
    }
    tree.native.closeFd(fd);
    engine.markDirty(target);
    engine.message = 'File created. Synchronization is queued.';
    return target;
  }

  /// Creates folder [name] in [parent] by an exclusive mkdir, reconciled by
  /// the next pass like a folder made locally on Linux: it inherits its
  /// parent's retention. (The Create folder action's journaled creation
  /// needs a synchronized parent; an app's folder need not wait for one.)
  String createFolder(String parent, String name) {
    final target = _newTarget(parent, name, directory: true);
    tree.native.checkRoot(tree.fd, tree.root.path);
    try {
      tree.native.makeDirExclusive(tree.fd, target);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 17) {
        throw const DocumentsFailure('exists', 'This name is already used.');
      }
      rethrow;
    }
    engine.markDirty(target);
    engine.message = 'Folder created. Synchronization is queued.';
    return target;
  }

  // ---- rename and move -----------------------------------------------------

  String relocate(String path, String parent, String name) {
    _notPaused();
    validateRelative(path);
    if (isTopFolder(path)) {
      // Spec #34 P7: renaming one would read as its deletion (restored).
      throw const DocumentsFailure(
        'refused',
        'Documents, Music and Videos cannot be renamed or moved.',
      );
    }
    if (parent.isNotEmpty) validateRelative(parent);
    final entry = engine.manifest.entries[path];
    final local = tree.statItem(path);
    if (local == null || local.identity == null) {
      throw const DocumentsFailure(
        'refused',
        'This item is in the cloud only. Keep it Local to rename or move it here.',
      );
    }
    if (entry != null && entry.kind != local.kind) {
      throw const DocumentsFailure(
        'refused',
        'This item changed. Check the folder and try again.',
      );
    }
    const mountOf = incomingMountOf;
    if (engine.viewOnly(path) ||
        engine.isIncomingMountPath(path) ||
        mountOf(path) != mountOf(_join(parent, name))) {
      throw const DocumentsFailure(
        'readOnly',
        'Items in a folder shared with you stay in that share.',
      );
    }
    if (parent == path || p.posix.isWithin(path, parent)) {
      throw const DocumentsFailure(
        'refused',
        'A folder cannot be moved into itself.',
      );
    }
    _writableFolder(parent);
    final within = engine.manifest.entries.values
        .where((e) => e.path == path || p.posix.isWithin(path, e.path))
        .toList();
    if (within.any(
      (e) =>
          e.kind == ItemKind.file &&
          e.etag != null &&
          !e.expectedPresent &&
          !(e.status.startsWith('delete')),
    )) {
      throw const DocumentsFailure(
        'refused',
        'This folder holds files that are in the cloud only. Keep it Local to move it here.',
      );
    }
    // A never-synchronized item's pending upload is settled as removed at
    // the old path by the next pass; a synchronized item's pending change
    // must finish first.
    if (engine.manifest.operations.values.any(
      (op) =>
          (op.path == path || p.posix.isWithin(path, op.path)) &&
          (const {'delete', 'working', 'finish-editing'}.contains(op.kind) ||
              (op.kind == 'upload' &&
                  engine.manifest.entries[op.path]?.etag != null)),
    )) {
      throw const DocumentsFailure(
        'busy',
        'This item has changes or open copies pending. Try again after the next sync.',
      );
    }
    if (registry.isPathOpen(path) ||
        within.any((e) => registry.isPathOpen(e.path))) {
      throw const DocumentsFailure('busy', 'This item is open in another app.');
    }
    final siblings = _siblings(parent)..remove(p.posix.basename(path));
    if (siblings.contains(name)) {
      throw const DocumentsFailure(
        'exists',
        'A file or folder already uses this name.',
      );
    }
    final target = _checkName(parent, name, siblings);
    if (target == path) return path;
    tree.native.checkRoot(tree.fd, tree.root.path);
    final synced = within.any((e) => e.etag != null);
    try {
      tree.native.renameExclusive(tree.fd, path, target, local.identity!);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 17) {
        throw const DocumentsFailure('exists', 'This name is already used.');
      }
      rethrow;
    }
    if (synced && entry?.etag != null) {
      // The cloud copy at the old path goes through the deletion intent;
      // the new path uploads as a new item in the same pass.
      engine.requestDelete(path);
    }
    engine.markDirty(path, descendants: true);
    engine.markDirty(target);
    engine.message = 'Renamed. Synchronization is queued.';
    return target;
  }

  // ---- delete --------------------------------------------------------------

  void delete(String path) {
    validateRelative(path);
    if (isTopFolder(path)) {
      throw const DocumentsFailure('refused', topFolderDeleteRefusal);
    }
    final entry = engine.manifest.entries[path];
    if (engine.viewOnly(path) || engine.isIncomingMountPath(path)) {
      throw const DocumentsFailure(
        'readOnly',
        'A folder shared with you is not deleted from another app.',
      );
    }
    if (entry?.etag != null) {
      try {
        engine.requestDelete(path);
      } on CloudFailure catch (error) {
        throw DocumentsFailure('refused', error.message);
      }
      return;
    }
    // Never synchronized: nothing to delete in the cloud.
    _notPaused();
    final local = tree.statItem(path);
    if (local == null || local.identity == null) {
      throw const DocumentsFailure('notFound', 'This item no longer exists.');
    }
    if (local.kind == ItemKind.directory) {
      try {
        tree.removeEmptyDirectory(path, local.identity!);
      } on FileSystemException {
        throw const DocumentsFailure(
          'refused',
          'This folder is not empty and has not synchronized yet. Delete its files first.',
        );
      }
    } else {
      _removeUnsynced(path);
    }
    engine.markDirty(path, descendants: true);
    engine.message = 'Deleted.';
  }

  /// Removes a never-synchronized root file under the release guard: the
  /// lease (and the registry) refuse a file another app holds open, the
  /// bytes move into private staging under a journaled name and are then
  /// unlinked through the same guard.
  void _removeUnsynced(String path) {
    if (registry.isPathOpen(path)) {
      throw const DocumentsFailure('busy', 'This file is open in another app.');
    }
    final artifacts = engine.artifacts;
    final native = artifacts.native;
    tree.native.checkRoot(tree.fd, tree.root.path);
    final info = native.info(tree.fd, path);
    final record = artifacts.reserve(path, 'discard', create: false);
    final name = p.basename(record.path);
    final op = artifacts.record(record)!;
    final int fd;
    try {
      fd = native.guard(tree.fd, path, info, links: 1);
    } on FileSystemException {
      engine.manifest.operations.remove(op.id);
      engine.manifest.save();
      throw const DocumentsFailure(
        'busy',
        'This file is open or changing. Try again when it is closed.',
      );
    }
    try {
      op.data['identity'] = info.identity;
      op.phase = 'quarantining';
      engine.manifest.save();
      native.valid(fd);
      native.quarantine(fd, tree.fd, path, tree.stageFd, name);
      tree.own(path);
      op.phase = 'reclaiming';
      engine.manifest.save();
      native.valid(fd);
      native.unlink(fd, tree.stageFd, name);
    } finally {
      native.close(fd);
    }
    engine.manifest.operations.remove(op.id);
    engine.manifest.save();
  }
}
