import 'dart:io';

import 'package:path/path.dart' as p;

import '../local/root_tree.dart';
import '../ports/phone_folders.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'artifacts.dart';
import 'open_documents.dart';

/// Explicit repair of missing working-copy records in Android phone folders.
/// The same inspection supplies the row's offer and checks the confirmation.
class MissingEditorCopies {
  MissingEditorCopies(this.manifest, this.tree, this.artifacts);

  final Manifest manifest;
  final RootTree tree;
  final Artifacts artifacts;

  static const missingWarning = 'Working copy missing; root/cloud retained';

  bool applies(String path) => tree.phoneFolders != null && inPhoneFolder(path);

  ({String? directory, Operation? owner, String? reason}) inspect(
    Entry entry,
    Operation work,
  ) {
    final routing = tree.phoneFolders!;
    final staged = work.staged;
    final name = staged == null ? '' : p.basename(staged);
    final shared = name.startsWith(sharedStagingTag);
    if (routing.paused) {
      return _keep('Phone storage is unavailable. Check All files access.');
    }
    if (staged == null ||
        staged != p.join(tree.staging.path, name) ||
        !name.startsWith(shared ? '${sharedStagingTag}working-' : 'working-')) {
      return _keep('The editor copy’s staging location could not be verified.');
    }

    String directory;
    String privateIdentity;
    try {
      tree.native.checkRoot(tree.stageFd, tree.staging.path);
      privateIdentity = tree.native.identity(tree.stageFd);
      directory = shared
          ? routing.checkedSharedStagingIdentity()
          : privateIdentity;
    } on FileSystemException {
      return _keep('The editor staging folder is unavailable or has changed.');
    }
    if (openDocuments.isWorkingCopyOpen(name)) {
      return _keep('An app still has the editor copy open.');
    }
    if (_absenceProblem(name) case final problem?) return _keep(problem);

    final neighbors = manifest.operations.values
        .where(
          (op) =>
              op.id != work.id &&
              (op.staged != null && p.basename(op.staged!) == name ||
                  op.data['name'] == name),
        )
        .toList();
    final owner = neighbors.length == 1 ? neighbors.single : null;
    if (entry.conflict != null ||
        manifest.entries.values.any(
          (row) =>
              _names(row.remoteCopy, name) ||
              row.preservedCopies.any((copy) => _names(copy, name)) ||
              row != entry && _names(row.workingCopy, name),
        ) ||
        neighbors.isNotEmpty &&
            (owner == null ||
                owner.kind != 'artifact' ||
                owner.path != entry.path ||
                (owner.data['entryPath'] ?? owner.path) != entry.path ||
                owner.staged != staged ||
                owner.data['name'] != name ||
                owner.data['role'] != 'working' ||
                owner.data['identity'] is! String ||
                owner.data['directoryIdentity'] != privateIdentity)) {
      return _keep('Other editor or recovery records refer to this copy.');
    }
    final identity = owner?.data['identity'];
    final ownerId = owner?.id;
    if (identity is String && openDocuments.isOpen(identity)) {
      return _keep('An app still has the editor copy open.');
    }
    if (work.data['reclaiming'] == true ||
        work.data['uploadTip'] != null ||
        owner != null &&
            (owner.phase != 'complete' ||
                owner.data['releasing'] != null ||
                owner.data['installing'] != null) ||
        manifest.operations.values.any(
          (op) =>
              op.data['workingId'] == work.id ||
              op.data['source'] == staged ||
              (op.data['names'] as List?)?.contains(staged) == true ||
              ownerId != null &&
                  (op.data['artifacts'] as List?)?.contains(ownerId) == true ||
              op.kind == 'edit-ownership' &&
                  op.phase == 'authorized' &&
                  (op.data['session'] == work.id ||
                      ownerId != null && op.data['artifact'] == ownerId) ||
              op.kind == 'finish-editing' &&
                  (op.data['sessions'] as List?)?.contains(work.id) == true,
        )) {
      return _keep(
        'Finishing, upload or recovery work still refers to this copy.',
      );
    }
    if (shared) {
      final recorded = owner?.data['sharedDirectoryIdentity'];
      if (recorded == null) {
        return _keep(
          'The original editor staging folder could not be verified.',
        );
      }
      if (recorded != directory) {
        return _keep('The editor staging folder has changed.');
      }
    }
    final tokens = work.data[providerOpenTokensKey];
    if (tokens is! List) {
      return _keep('Could not verify that all apps closed this editor copy.');
    }
    if (tokens.isNotEmpty) {
      return _keep('An app may still have the editor copy open.');
    }
    if (_checkAbsence(name, directory) case final problem?) {
      return _keep(problem);
    }
    return (directory: directory, owner: owner, reason: null);
  }

  String? _checkAbsence(String name, String directory) {
    try {
      tree.native.checkRoot(tree.stageFd, tree.staging.path);
      final current = name.startsWith(sharedStagingTag)
          ? tree.phoneFolders!.checkedSharedStagingIdentity()
          : tree.native.identity(tree.stageFd);
      if (current != directory) return 'The editor staging folder has changed.';
    } on FileSystemException {
      return 'The editor staging folder is unavailable or has changed.';
    }
    return _absenceProblem(name);
  }

  String? _absenceProblem(String name) {
    try {
      artifacts.native.info(tree.stageFd, name);
      return 'The editor copy is present.';
    } on FileSystemException catch (error) {
      // A lookup of one basename against the verified staging descriptor.
      return error.osError?.errorCode == 2
          ? null
          : 'The editor copy could not be checked.';
    }
  }

  static bool _names(String? staged, String name) =>
      staged != null && p.basename(staged) == name;

  static ({String? directory, Operation? owner, String? reason}) _keep(
    String reason,
  ) => (directory: null, owner: null, reason: reason);

  /// Confirmation runs synchronously on the owning worker. The manifest
  /// saves all accepted retirements in one transaction, with no file I/O
  /// mutations or cloud calls. An already retired ID is a no-op on replay.
  ({int cleared, List<String> kept}) clear(Entry entry, List<Map> claims) {
    final kept = <String>[];
    final removed = <Operation>[];
    final eligible = <Operation, (Operation?, String)>{};
    final oldPointer = entry.workingCopy;
    final oldStatus = entry.status;
    for (final claim in claims) {
      final work = manifest.operations[claim['id']];
      if (work == null) continue;
      if (work.kind != 'working' ||
          work.path != entry.path ||
          work.staged != claim['path']) {
        kept.add('The editor session changed. Review the current copies.');
        continue;
      }
      final result = inspect(entry, work);
      if (result.reason case final reason?) {
        kept.add(reason);
        continue;
      }
      if (result.directory != claim['directory'] ||
          result.owner?.id != claim['owner'] ||
          result.owner?.data['identity'] != claim['ownerIdentity'] ||
          work.data['handedAt'] != claim['handedAt']) {
        kept.add(
          'The editor staging records changed. Review the current copies.',
        );
        continue;
      }
      eligible[work] = (result.owner, result.directory!);
    }
    var cleared = 0;
    for (final MapEntry(key: work, value: (artifact, directory))
        in eligible.entries) {
      if (_checkAbsence(p.basename(work.staged!), directory)
          case final problem?) {
        kept.add(problem);
        continue;
      }
      if (artifact case final owner?) {
        removed.add(owner);
        manifest.operations.remove(owner.id);
      }
      removed.add(work);
      manifest.operations.remove(work.id);
      if (entry.workingCopy == work.staged) entry.workingCopy = null;
      cleared++;
    }
    if (cleared > 0) {
      if (entry.status == missingWarning) {
        entry.status = entry.expectedPresent ? 'current local' : 'cloud-only';
      }
      try {
        manifest.save();
      } catch (_) {
        // A later ordinary save must not retry an uncommitted clearance
        // without a new absence check.
        for (final op in removed) {
          manifest.operations[op.id] = op;
        }
        entry
          ..workingCopy = oldPointer
          ..status = oldStatus;
        rethrow;
      }
    }
    manifest.commitPoint();
    return (cleared: cleared, kept: kept);
  }
}
