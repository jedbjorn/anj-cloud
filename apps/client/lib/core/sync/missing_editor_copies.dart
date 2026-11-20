import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../local/root_tree.dart';
import '../ports/phone_folders.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'artifacts.dart';
import 'open_documents.dart';

typedef MissingEditorInspection = ({
  String? directory,
  Operation? owner,
  String? reason,
  bool legacy,
  bool cleanupUnconfirmed,
});

/// Explicit repair of missing working-copy records in Android phone folders.
/// The same inspection supplies the row's offer and checks the confirmation.
class MissingEditorCopies {
  MissingEditorCopies(this.manifest, this.tree, this.artifacts);

  final Manifest manifest;
  final RootTree tree;
  final Artifacts artifacts;

  static const missingWarning = 'Working copy missing; root/cloud retained';
  static const copyPresent = 'The editor copy is present.';
  static const _relatedWork =
      'Finishing, upload or recovery work still refers to this copy.';
  static const _noticeKey = 'missingEditorNotice';

  bool applies(String path) => tree.phoneFolders != null && inPhoneFolder(path);

  MissingEditorInspection inspect(Entry entry, Operation work) {
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
    if (_absenceProblem(name) case final problem?) return _keep(problem);
    if (openDocuments.isWorkingCopyOpen(name)) {
      return _keep('An app still has the editor copy open.');
    }

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
            (owner.phase != 'complete' || owner.data['installing'] != null) ||
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
      return _keep(_relatedWork);
    }
    final recorded = shared
        ? owner?.data['sharedDirectoryIdentity']
        : privateIdentity;
    if (recorded != null && recorded != directory) {
      return _keep('The editor staging folder has changed.');
    }
    final tokens = work.data[providerOpenTokensKey];
    if (tokens is List && tokens.isNotEmpty) {
      return _keep('An app may still have the editor copy open.');
    }
    if (_checkAbsence(name, directory) case final problem?) {
      return _keep(problem);
    }
    final closureUnknown =
        tokens is! List || work.data[providerClosureUnknownKey] == true;
    final releaseIntent = owner?.data['releasing'];
    if (releaseIntent != null) {
      // The build-177 intent was saved before unlink. With neither historic
      // shared directory nor closure proof, the current absence only explains
      // the notice. The same release guard still refuses Clear and Dismiss.
      if (shared &&
          recorded == null &&
          closureUnknown &&
          (tokens == null || tokens is List) &&
          releaseIntent is String &&
          releaseIntent.isNotEmpty) {
        return (
          directory: directory,
          owner: owner,
          reason: _relatedWork,
          legacy: false,
          cleanupUnconfirmed: true,
        );
      }
      return _keep(_relatedWork);
    }
    final reason = recorded == null
        ? 'The original editor staging folder could not be verified.'
        : closureUnknown
        ? 'Could not verify that all apps closed this editor copy.'
        : null;
    return (
      directory: directory,
      owner: owner,
      reason: reason,
      legacy: reason != null,
      cleanupUnconfirmed: false,
    );
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
      return copyPresent;
    } on FileSystemException catch (error) {
      // A lookup of one basename against the verified staging descriptor.
      return error.osError?.errorCode == 2
          ? null
          : 'The editor copy could not be checked.';
    }
  }

  static bool _names(String? staged, String name) =>
      staged != null && p.basename(staged) == name;

  static MissingEditorInspection _keep(String reason) => (
    directory: null,
    owner: null,
    reason: reason,
    legacy: false,
    cleanupUnconfirmed: false,
  );

  String _condition(Operation work, MissingEditorInspection proof) =>
      jsonEncode([
        work.staged,
        work.data['handedAt'],
        proof.directory,
        proof.owner?.id,
        proof.owner?.data['identity'],
        proof.reason,
      ]);

  Map? _notice(Operation work) => work.data[_noticeKey] as Map?;

  Object? _fileIdentity(Entry entry) => entry.fileId ?? entry.localIdentity;

  /// Describes the notice actions without creating, returning or saving a
  /// notice. A legacy condition would get a claim on ordinary projection.
  ({Object dismiss, Object undo, String? detailsOnlyMissingArtifact})
  diagnosticNotice(
    Entry entry,
    Operation work,
    String? binding,
    MissingEditorInspection? proof, {
    required bool recoveryAssessed,
    required bool observedPresent,
  }) {
    if (binding == null) {
      return (
        dismiss: 'unknown',
        undo: 'unknown',
        detailsOnlyMissingArtifact: null,
      );
    }
    final raw = work.data[_noticeKey];
    final notice =
        raw is Map &&
            raw['binding'] == binding &&
            raw['file'] == _fileIdentity(entry)
        ? raw
        : null;
    final legacy = proof?.legacy == true;
    final unchanged =
        legacy && notice?['condition'] == _condition(work, proof!);
    final dismissed =
        notice?['dismissed'] == true && notice?['revision'] != null;
    return (
      dismiss: recoveryAssessed
          ? legacy && !(unchanged && dismissed)
          : 'unknown',
      undo: !observedPresent && dismissed && (!legacy || unchanged),
      detailsOnlyMissingArtifact:
          proof?.cleanupUnconfirmed == true || unchanged && dismissed
          ? proof?.owner?.id
          : null,
    );
  }

  void observePresent(Operation work) {
    final notice = _notice(work);
    if (notice == null || notice['returned'] == true) return;
    // A return ends this missing notice, even if the name disappears again.
    _saveNotices({
      work: notice['dismissed'] == true ? {'returned': true} : null,
    });
  }

  Map<String, Object?> projectNotice(
    Entry entry,
    Operation work,
    String binding,
    MissingEditorInspection? proof,
  ) {
    var notice = _notice(work);
    final file = _fileIdentity(entry);
    if (notice?['binding'] != binding || notice?['file'] != file) {
      notice = null;
    }
    final legacy = proof?.legacy == true;
    if (legacy) {
      final condition = _condition(work, proof!);
      if (notice?['condition'] != condition) {
        notice = {
          'binding': binding,
          'file': file,
          'condition': condition,
          'revision': uniqueId(),
        };
        _saveNotices({work: notice});
      }
    }
    if (notice?['revision'] == null ||
        (!legacy && notice?['dismissed'] != true)) {
      return const {};
    }
    final dismissed = notice!['dismissed'] == true;
    final claim = {
      'binding': binding,
      'file': file,
      'id': work.id,
      'path': work.staged,
      'revision': notice['revision'],
    };
    return {
      if (dismissed)
        'undoEditorWarningClaim': claim
      else
        'dismissEditorWarningClaim': claim,
      if (legacy && dismissed) 'editorWarningDismissed': true,
      if (legacy && dismissed && proof!.owner != null)
        'detailsOnlyMissingArtifact': proof.owner!.id,
    };
  }

  bool returned(Operation work) => _notice(work)?['returned'] == true;

  String changeWarnings(
    Entry entry,
    String binding,
    List<Map> claims, {
    required bool undo,
  }) {
    final changes = <Operation, Object?>{};
    final kept = <String>{};
    final file = _fileIdentity(entry);
    for (final claim in claims) {
      final work = manifest.operations[claim['id']];
      if (claim['binding'] != binding ||
          claim['file'] != file ||
          work == null ||
          work.kind != 'working' ||
          work.path != entry.path ||
          work.staged != claim['path']) {
        kept.add('The file, paired profile or editor session changed.');
        continue;
      }
      final notice = _notice(work);
      if (notice == null ||
          notice['binding'] != binding ||
          notice['file'] != file ||
          notice['revision'] is! String ||
          notice['revision'] != claim['revision'] ||
          (notice['dismissed'] == true) != undo) {
        kept.add('The editor warning changed. Review the current copies.');
        continue;
      }
      if (!undo) {
        final proof = inspect(entry, work);
        if (proof.reason == copyPresent) observePresent(work);
        if (!proof.legacy || _condition(work, proof) != notice['condition']) {
          kept.add(
            proof.legacy || proof.reason == null
                ? 'The editor warning changed. Review the current copies.'
                : proof.reason!,
          );
          continue;
        }
      }
      changes[work] = {...notice, 'revision': uniqueId(), 'dismissed': !undo};
    }
    if (changes.isNotEmpty) _saveNotices(changes);
    final count = changes.length;
    return [
      if (count > 0)
        '${undo ? 'Restored' : 'Dismissed'} $count editor ${count == 1 ? 'warning' : 'warnings'}.',
      if (kept.isNotEmpty) kept.join(' '),
      if (count == 0 && kept.isEmpty) 'No editor warnings changed.',
    ].join(' ');
  }

  void _saveNotices(Map<Operation, Object?> states) {
    final previous = {for (final work in states.keys) work: _notice(work)};
    void apply(Map<Operation, Object?> updates) {
      for (final MapEntry(key: work, value: value) in updates.entries) {
        if (value == null) {
          work.data.remove(_noticeKey);
        } else {
          work.data[_noticeKey] = value;
        }
      }
    }

    apply(states);
    try {
      manifest.save();
    } catch (_) {
      apply(previous);
      rethrow;
    }
    manifest.commitPoint();
  }

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
