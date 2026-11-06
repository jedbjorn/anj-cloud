import '../state/model.dart';
import '../gateway/sharing.dart';
import 'name_policy.dart';
import 'top_folders.dart';
import 'sync_engine.dart';

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
    for (final operation in operations)
      if (operation.kind == 'working' &&
          operation.data['presentationError'] is String)
        operation.data['presentationError'] as String,
  ];
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
    ..['presentationNotes'] = [
      // The cloud's name won over a rename here (spec #33).
      ?entry.movedNote,
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
