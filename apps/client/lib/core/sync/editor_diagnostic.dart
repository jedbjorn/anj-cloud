import 'dart:io';

import 'package:path/path.dart' as p;

import '../ports/phone_folders.dart';
import '../ports/release_guard.dart';
import '../state/model.dart';
import 'missing_editor_copies.dart';
import 'name_policy.dart';
import 'name_rule.dart';
import 'open_documents.dart';
import 'sync_engine.dart';

const editorDiagnosticsEnabled = bool.fromEnvironment('ANJ_EDITOR_DIAGNOSTIC');
const editorDiagnosticRequest = 'editorDiagnostic';
const editorDiagnosticResult = 'editorDiagnosticResult';

/// Runs synchronously at a worker command boundary. The worker owns the
/// manifest, so no pass or other command can change these rows during the read.
Map<String, Object?>? readEditorDiagnostic(
  SyncEngine engine,
  Object? path,
  Object? selectionVersion, {
  required bool phoneStoragePaused,
}) {
  if (path is! String || !engine.missingEditors.applies(path)) return null;
  final entry = engine.manifest.entries[path];
  if (entry == null ||
      entry.kind != ItemKind.file ||
      selectionVersion != engine.selectionVersion(entry)) {
    return null;
  }
  return _EditorDiagnostic(
    engine,
    entry,
    phoneStoragePaused || engine.tree.phoneFolders!.paused,
  ).read();
}

class _EditorDiagnostic {
  _EditorDiagnostic(this.engine, this.entry, this.phoneStoragePaused)
    : operations = engine.manifest.operations.values.toList(growable: false);

  final SyncEngine engine;
  final Entry entry;
  final bool phoneStoragePaused;
  final List<Operation> operations;
  final _aliases = <String, String>{};
  late final _entryOperations = operations.where((op) => op.path == entry.path);
  late final _sessions = _entryOperations.where((op) => op.kind == 'working');
  late final _byId = {for (final op in operations) op.id: op};
  late final _binding = _readBinding();
  late final _private = _directory(shared: false);
  late final _shared = _directory(shared: true);

  static const _unknown = 'unknown';
  static const _kinds = {
    'artifact',
    'working',
    'finish-editing',
    'edit-ownership',
    'upload',
    'delete',
    'preserve',
    'retained',
    'evict',
    'move',
    'recover',
    'trash',
    'excluded-operation',
    'keep-both',
    'createFolder',
  };
  static const _roles = {
    'working',
    'working-upload',
    'finish-proof',
    'upload',
    'upload-recovery',
    'download',
    'preserved',
    'eviction-proof',
    'eviction-quarantine',
    'conflict',
    'conflict-local',
    'conflict-edited-copy',
    'excluded-recovery-proof',
    'check',
  };
  static const _phases = {
    'pending',
    'reserved',
    'owned',
    'complete',
    'authorized',
    'adopted',
    'superseded',
    'prepared',
    'proved',
    'quarantining',
    'quarantined',
    'reclaiming',
    'review',
    'writing',
    'written',
  };

  Map<String, Object?> read() {
    for (final (i, session) in _sessions.indexed) {
      _aliases[session.id] = 'session ${i + 1}';
    }
    return {
      'sessionSlots': [for (final work in _sessions) _session(work)],
      'entryWarnings': [
        if (entry.conflict != null) 'conflict',
        if (isSizeRefusal(entry.status)) 'size refusal',
        if (isCantSyncName(entry.status)) 'name refusal',
        if (isBusyStatus(entry.status)) 'busy file',
        if (entry.status.startsWith('Finish pending:')) 'Finish pending',
        if (entry.status == MissingEditorCopies.missingWarning)
          'stored missing editor warning',
        if (_entryOperations.any(
          (op) => const {'upload', 'delete', 'preserve'}.contains(op.kind),
        ))
          'sync work pending',
        if (_entryOperations.any((op) => op.kind == 'finish-editing'))
          'Finish request exists',
      ],
    };
  }

  Map<String, Object?> _session(Operation work) {
    final staged = work.staged;
    final name = staged == null ? null : p.basename(staged);
    final neighbors = [
      for (final op in operations)
        if (op != work &&
            name != null &&
            (op.staged != null && p.basename(op.staged!) == name ||
                op.data['name'] == name))
          op,
    ];
    final owners = neighbors
        .where(
          (op) =>
              op.kind == 'artifact' &&
              op.data['role'] == 'working' &&
              op.path == entry.path &&
              (op.data['entryPath'] ?? op.path) == entry.path &&
              op.staged == staged &&
              op.data['name'] == name,
        )
        .toList();
    final owner = owners.length == 1 ? owners.single : null;
    final ownerIds = {for (final op in owners) op.id};
    final references = <Map<String, Object?>>[];
    final uploads = <Map<String, Object?>>[];
    final tip = work.data['uploadTip'];
    final uploadRecords = operations
        .where(
          (op) =>
              op.kind == 'artifact' &&
              op.data['role'] == 'working-upload' &&
              (op.data['workingId'] == work.id || tip == op.id),
        )
        .toList();
    final live = <String>[
      if (work.data['reclaiming'] == true) 'session reclaiming',
      for (final record in owners) ...[
        if (record.phase != 'complete') 'owner incomplete ${_alias(record)}',
        if (record.data['installing'] != null)
          'owner installing ${_alias(record)}',
        if (record.data['releasing'] != null)
          'owner releasing ${_alias(record)}',
      ],
    ];
    final uncertain = <String>[
      if (owners.length != 1) 'working owner unresolved',
      if (tip != null && !_byId.containsKey(tip))
        'upload tip record unavailable',
    ];
    for (final op in operations) {
      final data = op.data;
      final workingId = data['workingId'] == work.id;
      final uploadTip = tip == op.id;
      final source = staged != null && data['source'] == staged;
      final names = staged != null && _contains(data['names'], staged);
      final artifacts = ownerIds.any((id) => _contains(data['artifacts'], id));
      final uploadArtifacts = [
        for (final upload in uploadRecords)
          if (_contains(data['artifacts'], upload.id) ||
              upload.staged != null &&
                  (data['source'] == upload.staged ||
                      _contains(data['names'], upload.staged!)))
            _alias(upload),
      ];
      final ownership =
          op.kind == 'edit-ownership' &&
          (data['session'] == work.id || ownerIds.contains(data['artifact']));
      final finish =
          op.kind == 'finish-editing' && _contains(data['sessions'], work.id);
      final relations = [
        if (owners.contains(op)) 'working owner candidate',
        if (neighbors.contains(op)) 'staging name reference',
        if (workingId) 'workingId',
        if (uploadTip) 'uploadTip target',
        if (source) 'source',
        if (names) 'names',
        if (artifacts) 'artifacts',
        if (uploadArtifacts.isNotEmpty) 'upload artifact reference',
        if (ownership && data['session'] == work.id) 'edit ownership session',
        if (ownership && ownerIds.contains(data['artifact']))
          'edit ownership artifact',
        if (ownership && op.phase == 'authorized') 'authorized edit ownership',
        if (finish) 'Finish membership',
      ];
      if (relations.isEmpty) continue;
      final upload = uploadRecords.contains(op);
      final uploadFacts = upload ? _upload(op, work) : null;
      if (uploadFacts != null) uploads.add(uploadFacts);
      final activeReference =
          source ||
          names ||
          artifacts ||
          uploadArtifacts.isNotEmpty ||
          finish ||
          ownership && op.phase == 'authorized';
      if (activeReference) {
        live.add('pending reference ${_alias(op)}');
      }
      if (workingId && !upload && !activeReference ||
          uploadTip && !upload ||
          (neighbors.contains(op) && !owners.contains(op) && !ownership)) {
        uncertain.add('unresolved reference ${_alias(op)}');
      }
      final obligation = uploadFacts?['obligation'];
      if (obligation == 'active') live.add('upload obligation ${_alias(op)}');
      if (obligation == _unknown) {
        uncertain.add('upload evidence ${_alias(op)}');
      }
      references.add({
        ..._operation(op),
        'relationships': relations,
        if (owners.contains(op))
          'ownerPredicates': {
            'incomplete': op.phase != 'complete',
            'installing': data['installing'] != null,
            'releasing': data['releasing'] != null,
          },
        if (uploadArtifacts.isNotEmpty) 'uploadArtifacts': uploadArtifacts,
      });
    }
    final target = _target(staged, owner);
    final recorded = owner?.data;
    final tokens = work.data[providerOpenTokensKey];
    final registryByName = name == null
        ? _unknown
        : openDocuments.isWorkingCopyOpen(name);
    final registryByIdentity = recorded?['identity'] is String
        ? openDocuments.isOpen(recorded!['identity'] as String)
        : _unknown;
    final closure = tokens is List && tokens.isNotEmpty
        ? 'outstanding'
        : tokens is! List || work.data[providerClosureUnknownKey] == true
        ? _unknown
        : 'closed';
    final edited = engine.artifacts.workingEdited(work);
    final preview = _finishPreview(work, phoneStoragePaused);
    final proof = edited && !preview && !phoneStoragePaused
        ? _inspect(work)
        : null;
    final warning = proof?.reason;
    final notice = engine.missingEditors.diagnosticNotice(
      entry,
      work,
      _binding,
      proof,
      recoveryAssessed: !edited || preview || proof != null,
      observedPresent: preview || warning == MissingEditorCopies.copyPresent,
    );
    return {
      'slot': _alias(work),
      'guardPredicates': {
        'reclaiming': work.data['reclaiming'] == true,
        'uploadTip': tip != null,
        'ownerIncomplete': owner == null ? _unknown : owner.phase != 'complete',
        'ownerInstalling': owner == null
            ? _unknown
            : recorded?['installing'] != null,
        'ownerReleasing': owner == null
            ? _unknown
            : recorded?['releasing'] != null,
        'ownerUniqueAmongNameReferences': name == null
            ? _unknown
            : owner != null && neighbors.length == 1,
      },
      'references': references,
      'entryReferences': {
        'selectedWorkingPointer': _names(entry.workingCopy, name),
        'otherWorkingPointer': engine.manifest.entries.values.any(
          (row) => row != entry && _names(row.workingCopy, name),
        ),
        'remoteCopy': engine.manifest.entries.values.any(
          (row) => _names(row.remoteCopy, name),
        ),
        'preservedCopy': engine.manifest.entries.values.any(
          (row) => row.preservedCopies.any((copy) => _names(copy, name)),
        ),
      },
      'acceptedUploads': uploads,
      'relationships': [
        if (uploads.any((facts) => facts['receipt'] == 'accepted'))
          'historical',
        if (live.isNotEmpty) 'active',
        if (uncertain.isNotEmpty) _unknown,
      ],
      'activeObligations': live,
      'uncertainty': uncertain,
      'staging': target,
      'providerClosure': {
        'inMemoryByName': registryByName,
        'inMemoryByOwnerIdentity': registryByIdentity,
        'durable': closure,
        'durableTokensOutstanding': tokens is List
            ? tokens.isNotEmpty
            : _unknown,
        'legacyClosureUnknown': work.data[providerClosureUnknownKey] == true,
      },
      'warnings': [
        if (phoneStoragePaused) 'phone storage unavailable',
        if (edited && !preview && proof == null)
          'editor recovery assessment unknown',
        ?warning,
        if (edited && proof != null && warning == null) 'missing editor copy',
        if (work.data['presentationError'] is String &&
            work.data['presentationError'] !=
                MissingEditorCopies.missingWarning)
          'independent editor presentation error',
        if (edited && preview && engine.missingEditors.returned(work))
          'editor copy returned',
      ],
      'actions': {
        'finishEditing': phoneStoragePaused && edited
            ? _unknown
            : edited && preview,
        'clearMissingEditorCopy': !edited || preview
            ? false
            : proof == null
            ? _unknown
            : proof.reason == null,
        'dismissWarning': edited ? notice.dismiss : false,
        'undoDismissal': edited ? notice.undo : false,
        'removeOpenedCopy': !edited,
      },
    };
  }

  Map<String, Object?> _upload(Operation op, Operation work) {
    final data = op.data;
    final session = _agreement(data['workingId'], work.id);
    final binding = _agreement(data['sessionBinding'], _binding);
    final sameEntry =
        op.path == entry.path && (data['entryPath'] ?? op.path) == entry.path;
    final hash = _agreement(op.hash, data['snapshotHash']);
    final identity = _agreement(data['identity'], data['snapshotIdentity']);
    final currentHash = _agreement(op.hash, work.hash);
    final currentVersion = _agreement(op.expectedEtag, work.expectedEtag);
    final successor = _byId[data['supersededBy']];
    final successorAgrees = successor == null
        ? _unknown
        : successor.kind == 'artifact' &&
              successor.data['role'] == 'working-upload' &&
              successor.data['workingId'] == work.id &&
              _binding != null &&
              successor.data['sessionBinding'] == _binding &&
              successor.path == entry.path &&
              (successor.data['entryPath'] ?? successor.path) == entry.path &&
              successor.data['lineageVersion'] == 1 &&
              successor.data['accepted'] == true &&
              successor.phase == 'complete' &&
              successor.data['supersedes'] == op.id &&
              _agreement(successor.data['baseEtag'], op.expectedEtag) ==
                  'match' &&
              _agreement(successor.hash, successor.data['snapshotHash']) ==
                  'match' &&
              _agreement(
                    successor.data['identity'],
                    successor.data['snapshotIdentity'],
                  ) ==
                  'match'
        ? 'match'
        : 'mismatch';
    final accepted = data['accepted'] == true;
    final obligations = [
      if (op.phase != 'complete') 'upload incomplete',
      if (data['installing'] != null) 'upload installing',
      if (data['releasing'] != null) 'upload releasing',
      if (data['accepted'] == false) 'upload unaccepted',
      for (final other in operations)
        if (other != op &&
            (_contains(other.data['artifacts'], op.id) ||
                op.staged != null &&
                    (other.data['source'] == op.staged ||
                        _contains(other.data['names'], op.staged!)) ||
                other.kind == 'finish-editing' &&
                    _contains(other.data['sessions'], work.id)))
          _alias(other),
    ];
    final matching = sameEntry && session == 'match' && binding == 'match';
    final validReceipt =
        matching &&
        accepted &&
        data['lineageVersion'] == 1 &&
        hash == 'match' &&
        identity == 'match' &&
        op.expectedEtag != null;
    final terminal =
        validReceipt &&
        (successorAgrees == 'match' ||
            data['supersededBy'] == null &&
                work.data['uploadTip'] == op.id &&
                currentVersion == 'match' &&
                currentHash == 'match');
    return {
      'record': _alias(op),
      'sameEntry': sameEntry,
      'session': session,
      'binding': binding,
      'lineageVersionSupported': data['lineageVersion'] == null
          ? _unknown
          : data['lineageVersion'] == 1,
      'accepted': data['accepted'] == null ? _unknown : accepted,
      'snapshotHash': hash,
      'snapshotIdentity': identity,
      'receipt': validReceipt ? 'accepted' : _unknown,
      'sessionHash': currentHash,
      'sessionVersion': currentVersion,
      'entryHash': _agreement(op.hash, entry.baselineHash),
      'entryVersion': _agreement(op.expectedEtag, entry.etag),
      'verifiedRemoteHash': _agreement(
        op.hash,
        entry.remoteHashEtag != null && entry.remoteHashEtag == op.expectedEtag
            ? entry.remoteHash
            : null,
      ),
      'supersession': successorAgrees,
      if (successor != null && successorAgrees == 'match')
        'successor': _alias(successor),
      'installing': data['installing'] != null,
      'releasing': data['releasing'] != null,
      'recordedObligations': obligations,
      'target': matching ? _target(op.staged, op) : _unknown,
      'obligation': matching && obligations.isNotEmpty
          ? 'active'
          : terminal
          ? 'terminal'
          : _unknown,
    };
  }

  String? _readBinding() {
    try {
      return engine.editing.binding;
    } on FileSystemException {
      return null;
    }
  }

  String? _directory({required bool shared}) {
    final tree = engine.tree;
    try {
      tree.native.checkRoot(tree.stageFd, tree.staging.path);
      if (!shared) return tree.native.identity(tree.stageFd);
      if (phoneStoragePaused || tree.phoneFolders!.paused) return null;
      return tree.phoneFolders!.checkedSharedStagingIdentity();
    } on FileSystemException {
      return null;
    }
  }

  Map<String, Object?> _target(String? staged, Operation? owner) {
    final tree = engine.tree;
    final name = staged == null ? null : p.basename(staged);
    final shared = name?.startsWith(sharedStagingTag) == true;
    final safe =
        name != null &&
        name != '.' &&
        name != '..' &&
        !name.contains('\\') &&
        !name.contains('\x00') &&
        staged == p.join(tree.staging.path, name);
    final directory = !safe
        ? null
        : shared
        ? _shared
        : _private;
    String target = _unknown;
    NativeFileInfo? info;
    if (directory != null && safe) {
      try {
        info = engine.artifacts.native.info(tree.stageFd, name);
        target = 'present';
      } on FileSystemException catch (error) {
        target = error.osError?.errorCode == 2 ? 'absent' : 'read error';
      }
      if (_directory(shared: shared) != directory) {
        info = null;
        target = 'directory changed during lookup';
      }
    }
    final data = owner?.data;
    final identity = _agreement(info?.identity, data?['identity']);
    final historical =
        data?[shared ? 'sharedDirectoryIdentity' : 'directoryIdentity'];
    return {
      'route': !safe
          ? _unknown
          : shared
          ? 'shared'
          : 'private',
      'access': !safe
          ? _unknown
          : directory == null
          ? 'unavailable'
          : 'accessible',
      'recordedPrivateDirectory': _agreement(
        _private,
        data?['directoryIdentity'],
      ),
      'historicalTargetDirectory': _agreement(directory, historical),
      'recordedName': _agreement(name, data?['name']),
      'target': identity == 'mismatch'
          ? 'present with identity mismatch'
          : target,
      'targetIdentity': identity,
      'targetStamp': _agreement(info?.stamp, data?['stamp']),
    };
  }

  bool _finishPreview(Operation work, bool paused) {
    if (paused || work.staged == null || _private == null) return false;
    try {
      final file = engine.artifacts.resolve(work.staged!);
      final record = engine.artifacts.record(file);
      if (record?.data['directoryIdentity'] != _private) return false;
      engine.artifacts.native.preview(
        engine.tree.stageFd,
        p.basename(file.path),
      );
      return true;
    } on FileSystemException {
      return false;
    }
  }

  MissingEditorInspection? _inspect(Operation work) {
    try {
      return engine.missingEditors.inspect(entry, work);
    } on TypeError {
      // An old or malformed relationship can be reported above even if the
      // ordinary guard cannot interpret it.
      return null;
    }
  }

  String _alias(Operation op) =>
      _aliases.putIfAbsent(op.id, () => 'record ${_aliases.length + 1}');

  Map<String, Object?> _operation(Operation op) => {
    'record': _alias(op),
    'kind': _kinds.contains(op.kind) ? op.kind : 'other',
    'role': _roles.contains(op.data['role']) ? op.data['role'] : _unknown,
    'phase': _phases.contains(op.phase) ? op.phase : 'other',
    'entry': op.path == entry.path ? 'selected' : 'other',
  };

  static bool _contains(Object? list, Object value) =>
      list is List && list.contains(value);

  static bool _names(String? staged, String? name) =>
      staged != null && name != null && p.basename(staged) == name;

  static String _agreement(Object? left, Object? right) =>
      left is! String || right is! String
      ? _unknown
      : left == right
      ? 'match'
      : 'mismatch';
}
