import 'dart:io';

import 'package:path/path.dart' as p;

import '../ports/release_guard.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';

/// Display kind of a staging role (upload, download, recovery, editing,
/// check); unknown roles are `other`.
String artifactKind(String? role) => switch (role) {
  'preserved' ||
  'eviction-quarantine' ||
  'conflict-local' ||
  'conflict-edited-copy' => 'recovery',
  'upload' || 'upload-recovery' => 'upload',
  'download' ||
  'conflict' ||
  'eviction-proof' ||
  'finish-proof' ||
  'excluded-recovery-proof' => 'download',
  'working' || 'working-upload' => 'editing',
  'check' => 'check',
  _ => 'other',
};

/// Records ownership before creation. Names and matching hashes never confer
/// ownership on an untracked/legacy staging file.
class Artifacts {
  Artifacts(this.manifest, this.tree) : native = tree.native.releaseGuard();
  final Manifest manifest;
  final RootTree tree;
  final ReleaseGuard native;
  Iterable<Operation> get records =>
      manifest.operations.values.where((o) => o.kind == 'artifact');
  Operation? record(File file) =>
      records.where((o) => o.staged == tree.durablePath(file)).firstOrNull;
  File reserve(String path, String role, {bool create = true}) {
    final name =
        '$role-${uniqueId()}${role == 'working' ? '-${p.posix.basename(path)}' : ''}';
    final file = File(p.join(tree.staging.path, name));
    final op =
        Operation(
            uniqueId(),
            'artifact',
            path,
            staged: file.path,
            phase: 'reserved',
          )
          ..data = {
            'role': role,
            'name': name,
            'directoryIdentity': tree.native.identity(tree.stageFd),
          };
    manifest.operations[op.id] = op;
    manifest.save();
    if (create) {
      final fd = native.create(tree.stageFd, name);
      try {
        op.data['identity'] = native.infoFd(fd).identity;
        op.phase = 'owned';
        manifest.save();
      } finally {
        tree.native.closeFd(fd);
      }
    }
    return tree.stagedFile(file.path);
  }

  void complete(File file, {String? hash, String? etag, bool moved = false}) {
    final op = record(file);
    if (op == null) {
      throw const FileSystemException('Staging ownership is unknown.');
    }
    final info = native.info(tree.stageFd, op.data['name'] as String);
    if (!moved && op.data['identity'] != info.identity) {
      throw const FileSystemException('Staged file identity changed.');
    }
    op.data['identity'] = info.identity;
    op.data['stamp'] = info.stamp;
    op.hash = hash;
    op.expectedEtag = etag;
    op.phase = 'complete';
    manifest.save();
  }

  /// Prefix of the private copy an install makes where the platform cannot
  /// hard-link (Android, native/posix/compat_android.h).
  static const installTempPrefix = '.anj-install-';

  /// Removes copies left in staging by an install that was interrupted
  /// before its rename (decision #130 (4)), so they never make staging look
  /// uncertain and hold back Cloud release. Only names with
  /// [installTempPrefix] that no manifest record mentions are removed; such a
  /// name is never recorded, so it cannot be anyone's artifact. Called at
  /// engine start, before any install can run. Returns the names removed.
  List<String> removeInterruptedInstalls() {
    final mentioned = <String>{
      for (final op in manifest.operations.values) ...[
        if (op.staged != null) p.basename(op.staged!),
        if (op.data['name'] is String) op.data['name'] as String,
      ],
    };
    final removed = <String>[];
    for (final item in tree.native.scan(tree.stageFd)) {
      final name = item['path'] as String;
      if (item['kind'] != 'file' ||
          name.contains('/') ||
          !name.startsWith(installTempPrefix) ||
          mentioned.contains(name)) {
        continue;
      }
      try {
        tree.stagedFile(p.join(tree.staging.path, name)).deleteSync();
        removed.add(name);
      } on FileSystemException {
        // Left for the next start; staging stays uncertain meanwhile.
      }
    }
    return removed;
  }

  /// The staged file at [staged] became a root file (an install that renames,
  /// decision #123 (2)): nothing in staging holds those bytes any more, so
  /// every reference to the name goes, as a release would remove them.
  void consumed(String staged) {
    manifest.operations.removeWhere(
      (_, o) =>
          o.staged == staged && (o.kind == 'artifact' || o.kind == 'retained'),
    );
    for (final entry in manifest.entries.values) {
      entry.preservedCopies.remove(staged);
      if (entry.remoteCopy == staged) entry.remoteCopy = null;
    }
  }

  /// A rename install interrupted by a restart: when the staged name is gone
  /// the rename happened (staging holds nothing for it any more) and the
  /// record is finalized; when the staged file is still there it never moved,
  /// and the intent is dropped so the engine installs again.
  void finishInterruptedMoves() {
    final pending = records
        .where((o) => o.data['installing'] is String)
        .toList();
    if (pending.isEmpty) return;
    for (final op in pending) {
      final name = op.data['name'] as String;
      final listed = tree.native.watchScan(null, tree.stageFd, name, false);
      if (listed.items.isNotEmpty) {
        op.data.remove('installing');
        continue;
      }
      consumed(op.staged!);
    }
    manifest.save();
  }

  bool get hasLegacyOrUncertain {
    final known = {for (final op in records) op.data['name'] as String: op};
    for (final file in tree.native.scan(tree.stageFd)) {
      final op = known[file['path']];
      if (op == null ||
          op.data['identity'] == null ||
          op.data['directoryIdentity'] != tree.native.identity(tree.stageFd)) {
        return true;
      }
      if (file['kind'] != 'file') {
        return true;
      }
      final current = native.info(tree.stageFd, file['path'] as String);
      if (current.identity != op.data['identity']) {
        return true;
      }
    }
    return false;
  }

  File resolve(String path) => tree.stagedFile(path);
}
