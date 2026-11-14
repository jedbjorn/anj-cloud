import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';
import 'sync_path_policy.dart';

/// The policy intent precedes publication of the exact private directory inode.
/// Ambiguous publication after interruption stays pending without applying policy.
class FolderCreation {
  FolderCreation(this.manifest, this.tree, {this.shown = _literal});
  final Manifest manifest;
  final RootTree tree;

  /// A local path under its cloud spelling, for messages (decision #193).
  final String Function(String local) shown;

  static String _literal(String local) => local;

  /// Creates [name], this device's local spelling; [cloudName] is the typed
  /// cloud name when it differs, recorded with the journaled intent so the
  /// folder leaves under it (spec #49 R3).
  Future<String> create(
    String parent,
    String name,
    Retention retention, {
    String? cloudName,
  }) async {
    if (name.trim().isEmpty || name.contains('/') || name.contains('\\')) {
      throw const FileSystemException(
        'Enter a folder name without path separators.',
      );
    }
    validateRelative(name);
    if (parent.isNotEmpty) validateRelative(parent);
    final path = parent.isEmpty ? name : '$parent/$name';
    if (isSyncExcluded(path)) {
      throw const FileSystemException(
        'This name is excluded from synchronization. Choose another name.',
      );
    }
    // Existence, type and identity only: no file content is read.
    final local = tree.scanItems(includeExcluded: true);
    if (local.containsKey(path) ||
        manifest.entries.containsKey(path) ||
        manifest.operations.values.any((op) => op.path == path)) {
      throw const FileSystemException(
        'A file or folder already uses this name. Choose another name.',
      );
    }
    if (manifest.operations.values.any(
      (op) =>
          op.kind == 'delete' &&
          (op.path == parent || p.posix.isWithin(op.path, path)),
    )) {
      throw const FileSystemException(
        'The parent folder has a pending deletion. Choose another location.',
      );
    }
    final parentEntry = manifest.entries[parent];
    if (parent.isNotEmpty &&
        (local[parent]?.kind != ItemKind.directory ||
            parentEntry == null ||
            parentEntry.kind != ItemKind.directory ||
            !parentEntry.expectedPresent ||
            parentEntry.status.startsWith('deleted') ||
            parentEntry.conflict != null)) {
      throw const FileSystemException(
        'The parent folder is unavailable locally or needs review. Choose another location.',
      );
    }
    final parentIdentity = parent.isEmpty
        ? tree.native.identity(tree.fd)
        : local[parent]!.identity!;
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    final staged = tree.stageName('folder', forPath: path);
    tree.native.makeDirExclusive(tree.stageFd, staged);
    final identity = tree.native.directoryIdentity(tree.stageFd, staged);
    final op = Operation(uniqueId(), 'createFolder', path, staged: staged)
      ..data.addAll({
        'identity': identity,
        'parentIdentity': parentIdentity,
        'retention': retention.name,
        'cloudName': ?cloudName,
      });
    manifest.operations[op.id] = op;
    manifest.save();
    complete(op);
    return path;
  }

  List<String> get pendingPaths => manifest.operations.values
      .where((op) => op.kind == 'createFolder')
      .map((op) => op.path)
      .toList();

  String? recover() {
    String? warning;
    for (final op
        in manifest.operations.values
            .where((op) => op.kind == 'createFolder')
            .toList()) {
      if (op.phase != 'review') {
        try {
          complete(op);
          continue;
        } on FileSystemException catch (error) {
          op.phase = 'review';
          op.data['error'] = error.message;
          manifest.save();
        }
      }
      warning ??= 'Folder ${_shownOf(op)} pending: ${op.data['error']}';
    }
    return warning;
  }

  /// The pending folder's cloud path: its recorded cloud name under its
  /// parent's cloud path.
  String _shownOf(Operation op) {
    final name = op.data['cloudName'] as String?;
    if (name == null) return shown(op.path);
    final parent = p.posix.dirname(op.path);
    return parent == '.' ? name : '${shown(parent)}/$name';
  }

  void complete(Operation op) {
    tree.native.checkRoot(tree.fd, tree.root.path);
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    try {
      tree.native.directoryIdentity(tree.stageFd, op.staged!);
    } on FileSystemException {
      throw const FileSystemException(
        'Folder creation needs review after interruption. Existing folders and storage choices were preserved.',
      );
    }
    tree.native.installDirectory(
      tree.fd,
      tree.stageFd,
      op.staged!,
      op.path,
      op.data['parentIdentity'] as String,
      op.data['identity'] as String,
    );
    tree.own(op.path);
    tree.native.checkRoot(tree.fd, tree.root.path);
    final actual = tree.native.directoryIdentity(tree.fd, op.path);
    if (actual != op.data['identity'] ||
        manifest.entries.containsKey(op.path)) {
      throw const FileSystemException(
        'Folder creation changed or collided; storage choices were not applied.',
      );
    }
    final entry = Entry(op.path, ItemKind.directory)
      ..override = Retention.values.byName(op.data['retention'] as String)
      ..awaitingFolderUpload = true
      ..expectedPresent = true
      ..cloudName = op.data['cloudName'] as String?;
    manifest.entries[op.path] = entry;
    manifest.operations.remove(op.id);
    try {
      manifest.save();
    } catch (_) {
      manifest.entries.remove(op.path);
      manifest.operations[op.id] = op;
      rethrow;
    }
  }
}
