import 'package:path/path.dart' as p;

import '../gateway/sharing.dart';
import '../state/model.dart';
import 'entry_projection.dart';
import 'open_documents.dart';
import 'sync_engine.dart';
import 'sync_path_policy.dart';

typedef SendLibraryMove = Future<void> Function(
  RemoteItem file,
  String destination,
  int? parentId,
  String? job,
);

/// The worker serializes this action with sync. A server-side MOVE is then
/// reconciled by the ordinary cloud-rename path, including device retention.
class LibraryMove {
  LibraryMove(this.engine, this.open, this.send);
  final SyncEngine engine;
  final OpenDocuments open;
  final SendLibraryMove? send;

  bool _available(String path) {
    final local = engine.names.localPath(path);
    return !isSyncExcluded(local) &&
        !engine.viewOnly(local) &&
        !engine.phoneFolderPaused(local) &&
        !deleteQueued(engine, local) &&
        engine.manifest.entries[local]?.conflict == null;
  }

  Future<Map<String, Object?>> handle(String op, Map command) async {
    if (send == null || engine.manifest.setting('accountRights') == 'read') {
      throw const CloudFailure(
        'A paired device with write access is required.',
      );
    }
    final account = [
      for (final key in ['server', 'accountUid', 'deviceId'])
        engine.manifest.setting(key),
    ].join('\n');
    if (op == 'moveFiles' && command['account'] != account) {
      throw const CloudFailure(
        'The active account changed. Choose the files again.',
      );
    }
    final listing = await engine.cloud.snapshot();
    final files = (command['files'] as List).cast<Map>();
    if (op == 'moveChoices') {
      final folders = <String, int?>{'': null};
      for (final folder in listing) {
        if (folder.kind != ItemKind.directory ||
            folder.fileId == null ||
            !_available(folder.path) ||
            (folder.permissions != null && !folder.permissions!.contains('C')))
          continue;
        folders[folder.path] = folder.fileId;
      }
      final job = command['job'];
      if (job != null) {
        final resolved = listing
            .where(
              (item) =>
                  item.kind == ItemKind.file &&
                  item.fileId == command['fileId'],
            )
            .singleOrNull;
        if (resolved == null || resolved.fileId == null) {
          throw const CloudFailure(
            'The original download could not be identified. Choose the file itself in Library.',
          );
        }
        return {
          'folders': folders,
          'account': account,
          'files': [
            {
              'path': resolved.path,
              'fileId': resolved.fileId,
              'etag': resolved.etag,
              'job': job,
            },
          ],
        };
      }
      return {'folders': folders, 'account': account, 'files': files};
    }

    final byPath = {for (final item in listing) item.path: item};
    final parent = command['folder'] as String;
    if (parent.isNotEmpty &&
        (byPath[parent]?.kind != ItemKind.directory ||
            command['parentId'] == null ||
            byPath[parent]?.fileId != command['parentId'] ||
            !_available(parent))) {
      throw const CloudFailure(
        'The destination folder changed. Choose it again.',
      );
    }
    final results = <String>[];
    for (final selected in files) {
      final path = selected['path'] as String;
      try {
        final file = byPath[path];
        if (file == null ||
            file.kind != ItemKind.file ||
            file.fileId == null ||
            file.fileId != selected['fileId'] ||
            file.etag != selected['etag']) {
          throw const CloudFailure('File changed or has not synced yet.');
        }
        final local = engine.names.localPath(path);
        final entry = engine.manifest.entries[local];
        if (!_available(path) ||
            (file.permissions != null &&
                permissionsViewOnly(file.permissions!, directory: false))) {
          throw const CloudFailure('File is unavailable or view only.');
        }
        if (selected['job'] == null &&
            (entry == null ||
                engine.selectionVersion(entry) !=
                    selected['selectionVersion'])) {
          throw const CloudFailure(
            'Selection changed. Select this file again.',
          );
        }
        final to = parent.isEmpty
            ? p.posix.basename(path)
            : p.posix.join(parent, p.posix.basename(path));
        if (to == path) {
          results.add('$path is already here.');
          continue;
        }
        final dest = engine.names.localPath(to);
        if (engine.mountOf(local) != engine.mountOf(dest)) {
          throw const CloudFailure(
            'Files shared with you must stay within their share.',
          );
        }
        final here = engine.tree.statItem(local);
        if (here?.identity != engine.localIdentities[local] ||
            (entry != null &&
                (entry.fileId != file.fileId ||
                    entry.etag != file.etag ||
                    here != null &&
                        ((entry.localStamp != null && here.scanStamp != entry.localStamp) ||
                            entry.localHash != entry.baselineHash))) ||
            open.isPathOpen(local) ||
            engine.manifest
                .operationsAt(local)
                .any((o) => o.kind != 'artifact')) {
          throw const CloudFailure(
            'Local changes or open copies need attention before moving.',
          );
        }
        if (byPath.containsKey(to) ||
            engine.tree.statItem(dest) != null ||
            engine.manifest.operationsAt(dest).isNotEmpty) {
          throw const CloudFailure(
            'The destination already contains this name.',
          );
        }
        await send!(
          file,
          to,
          command['parentId'] as int?,
          selected['job'] as String?,
        );
        results.add(
          'Moved $path to ${parent.isEmpty ? "the library root" : parent}.',
        );
      } catch (error) {
        results.add('$path: $error');
      }
    }
    return {'results': results};
  }
}
