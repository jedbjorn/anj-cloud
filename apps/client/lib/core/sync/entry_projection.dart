import '../state/model.dart';
import '../gateway/sharing.dart';
import 'name_policy.dart';
import 'top_folders.dart';
import 'sync_engine.dart';

/// A Cloud-only file still on this device because a release guard holds it
/// (spec #45 R5): the pass releases it once the condition clears.
const freesWhenClosed = 'Frees space when closed';
const freesAfterUpload = 'Frees space after upload';
const freesAfterConflict = 'Frees space once the conflict is resolved';

/// The statuses the release guards leave on a file waiting for its upload.
const releaseWaitsForUpload = {
  'Cloud pending: pending work is retained.',
  'Cloud pending: local bytes are not yet clean and synchronized.',
};

String? releaseNote(
  SyncEngine engine,
  Entry entry,
  List<Operation> operations,
) {
  final here =
      entry.expectedPresent || engine.localIdentities[entry.path] != null;
  if (entry.kind != ItemKind.file ||
      !here ||
      engine.retention(entry.path) != Retention.cloud) {
    return null;
  }
  if (isBusyStatus(entry.status) ||
      entry.status.contains('filesystem guard refused')) {
    return freesWhenClosed;
  }
  if (entry.conflict != null) return freesAfterConflict;
  if (entry.etag == null ||
      releaseWaitsForUpload.contains(entry.status) ||
      operations.any((o) => const {'upload', 'preserve'}.contains(o.kind))) {
    return freesAfterUpload;
  }
  return null;
}

/// Current sync facts supplied to every library tab, without mutating policy.
Future<Map<String, Object?>> projectEntry(
  SyncEngine engine,
  Entry entry,
) async {
  final operations = engine.manifest.operationsAt(entry.path).toList();
  final errors = [
    // Too large for the server: shown, and amber, until the file changes.
    if (isSizeRefusal(entry.status)) entry.status,
    // Name not allowed on other devices (decision #120): amber, with Rename.
    if (isNameRefusal(entry.status)) entry.status,
    // A server name this device cannot hold (#120 Q2): amber, no Rename.
    if (isServerNameHold(entry.status)) entry.status,
    // Open in another app without read sharing (SC-048 F5): amber until
    // a pass can read it.
    if (isBusyStatus(entry.status)) entry.status,
    for (final operation in operations)
      if (operation.kind == 'working' &&
          operation.data['presentationError'] is String)
        operation.data['presentationError'] as String,
  ];
  final release = releaseNote(engine, entry, operations);
  return (entry.toJson()
      ..removeWhere((key, _) => Entry.indexKeys.contains(key)))
    ..['selectionVersion'] = engine.selectionVersion(entry)
    // The documents provider binds folder approvals to it (spec #28 A5).
    ..['localIdentity'] = engine.localIdentities[entry.path]
    ..['localDirectoryAvailable'] =
        entry.kind == ItemKind.directory &&
        entry.expectedPresent &&
        !entry.status.startsWith('deleted') &&
        engine.localDirectories.contains(entry.path)
    ..['effectiveRetention'] = engine.retention(entry.path).name
    // A top folder's own choice for what is inside it (decision #163).
    ..['contentsRetention'] = isTopFolder(entry.path)
        ? (entry.override ?? engine.defaultRetention).name
        : null
    ..['workingCopies'] = engine.workingCopies(entry.path)
    ..['finishPending'] = operations.any(
      (operation) => operation.kind == 'finish-editing',
    )
    ..['syncPending'] =
        errors.isNotEmpty ||
        operations.any(
          (operation) =>
              ['upload', 'delete', 'preserve'].contains(operation.kind),
        )
    ..['presentationErrors'] = errors
    // Information only: it syncs as any other row.
    ..['releaseNote'] = release
    ..['presentationNotes'] = [
      // The cloud's name won over a rename here (spec #33).
      ?entry.movedNote,
      ?release,
      if (engine.notesLongPaths &&
          engine.tree.root.path.length + 1 + entry.path.length > win32MaxPath)
        longPathNote,
    ]
    ..['nameRefused'] = isNameRefusal(entry.status)
    // Recent ranks such a file by its local modification time.
    ..['pendingLocalEdit'] =
        entry.kind == ItemKind.file &&
        ((entry.localHash != null && entry.localHash != entry.baselineHash) ||
            operations.any((operation) => operation.kind == 'upload'))
    ..['hasRecovery'] = operations.any(
      (operation) => operation.kind == 'retained',
    )
    ..['localArtifacts'] = engine.localArtifacts(entry.path)
    // Retained recovery copies Recover and Dismiss act on (spec #25).
    ..['recoveryCopies'] = engine.recovery.describe(entry.path)
    ..['canRecoverLocalVariants'] = await engine.canRecoverLocalVariants(
      entry.path,
    )
    // Directory sharing (spec #26): the incoming share mounted at this row,
    // View only scope and the names this account's folder is shared with.
    ..['incomingShare'] = engine.incoming[entry.path]?.toJson()
    ..['viewOnly'] = engine.viewOnly(entry.path)
    ..['inSharedFolder'] = inSharedFolder(entry.path)
    // An incoming share or inside one, wherever it is mounted (spec #34 P6).
    ..['inIncomingShare'] = engine.inIncomingShare(entry.path)
    ..['incomingMount'] = engine.isIncomingMountPath(entry.path)
    ..['sharedWith'] = engine.outgoingNames[entry.path];
}
