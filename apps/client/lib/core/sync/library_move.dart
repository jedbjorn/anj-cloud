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
  LibraryMove(this.engine, this.open, this.send, {this.relocate});
  final SyncEngine engine;
  final OpenDocuments open;
  final SendLibraryMove? send;
  final String Function(String path, String parent, String name)? relocate;

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
      return _choices(command, files, listing, account);
    }

    final byPath = {for (final item in listing) item.path: item};
    final parent = command['folder'] as String;
    final folder = byPath[parent];
    if (parent.isNotEmpty &&
        (folder?.kind != ItemKind.directory ||
            command['parentId'] == null ||
            folder?.fileId != command['parentId'] ||
            !(folder?.permissions?.contains('C') ?? true) ||
            !_available(parent))) {
      throw const CloudFailure(
        'The destination folder changed. Choose it again.',
      );
    }
    final results = <String>[];
    for (final selected in files) {
      final path = selected['path'] as String;
      try {
        results.add(
          await _move(
            selected,
            path,
            parent,
            command['parentId'] as int?,
            byPath,
          ),
        );
      } catch (error) {
        results.add('$path: $error');
      }
    }
    return {'results': results};
  }

  Map<String, Object?> _choices(
    Map command,
    List<Map> selected,
    List<RemoteItem> listing,
    String account,
  ) {
    final job = command['job'];
    if (job != null) {
      final file = listing
          .where(
            (item) =>
                item.kind == ItemKind.file &&
                item.fileId != null &&
                item.fileId == command['fileId'],
          )
          .singleOrNull;
      if (file == null) {
        throw const CloudFailure(
          'The original download could not be identified. Choose the file itself in Library.',
        );
      }
      selected = [
        {
          'path': file.path,
          'fileId': file.fileId,
          'etag': file.etag,
          'job': job,
        },
      ];
    }
    final mounts = {
      for (final source in selected)
        engine.mountOf(engine.names.localPath(source['path'] as String)),
    };
    final folders = <String, int?>{if (mounts.contains(null)) '': null};
    for (final folder in listing) {
      if (folder.kind == ItemKind.directory &&
          folder.fileId != null &&
          _available(folder.path) &&
          (folder.permissions?.contains('C') ?? true) &&
          mounts.contains(
            engine.mountOf(engine.names.localPath(folder.path)),
          )) {
        folders[folder.path] = folder.fileId;
      }
    }
    return {'folders': folders, 'account': account, 'files': selected};
  }

  bool _localChanged(String path, Entry? entry, RemoteItem remote) {
    final here = engine.tree.statItem(path);
    if ((entry?.expectedPresent ?? false) != (here != null) ||
        here?.identity != engine.localIdentities[path]) {
      return true;
    }
    if (entry == null) return false;
    if (entry.fileId != remote.fileId || entry.etag != remote.etag) return true;
    if (here == null) return false;
    if (entry.localHash != entry.baselineHash) return true;
    if (entry.localStamp != null) {
      return here.scanStamp != entry.localStamp ||
          entry.stampHash != entry.baselineHash;
    }
    final current = engine.tree.native.copyAndHashStamped(
      engine.tree.fd,
      path,
      null,
      purpose: 'scan',
    );
    return current.hash != entry.baselineHash;
  }

  Future<String> _move(
    Map selected,
    String path,
    String parent,
    int? parentId,
    Map<String, RemoteItem> byPath,
  ) async {
    final file = byPath[path];
    final local = engine.names.localPath(path);
    final entry = engine.manifest.entries[local];
    final unsynced =
        selected['job'] == null &&
        selected['fileId'] == null &&
        selected['etag'] == null &&
        file == null &&
        entry?.kind == ItemKind.file &&
        entry?.etag == null &&
        entry?.fileId == null &&
        entry?.baselineHash == null;
    if (!unsynced &&
        (file == null ||
            file.kind != ItemKind.file ||
            file.fileId == null ||
            file.fileId != selected['fileId'] ||
            file.etag != selected['etag'])) {
      throw const CloudFailure('File changed or has not synced yet.');
    }
    if (!_available(path) ||
        (file?.permissions != null &&
            permissionsViewOnly(file!.permissions!, directory: false))) {
      throw const CloudFailure('File is unavailable or view only.');
    }
    if (selected['job'] == null &&
        (entry == null ||
            engine.selectionVersion(entry) != selected['selectionVersion'])) {
      throw const CloudFailure('Selection changed. Select this file again.');
    }
    final to = parent.isEmpty
        ? p.posix.basename(path)
        : p.posix.join(parent, p.posix.basename(path));
    if (to == path) {
      return '$path is already here.';
    }
    final dest = engine.names.localPath(to);
    if (engine.mountOf(local) != engine.mountOf(dest)) {
      throw const CloudFailure(
        'Files shared with you must stay within their share.',
      );
    }
    if (byPath.containsKey(to) ||
        engine.manifest.entries.containsKey(dest) ||
        engine.tree.statItem(dest) != null ||
        engine.manifest.operationsAt(dest).isNotEmpty) {
      throw const CloudFailure('The destination already contains this name.');
    }
    if (unsynced) {
      final identity = engine.localIdentities[local];
      if (relocate == null ||
          identity == null ||
          engine.tree.statItem(local)?.identity != identity ||
          engine.manifest
              .operationsAt(local)
              .any((op) => op.kind != 'upload')) {
        throw const CloudFailure(
          'The local file changed. Select it again after sync.',
        );
      }
      relocate!(local, engine.names.localPath(parent), p.posix.basename(dest));
      return 'Moved $path on this device. Sync is queued.';
    }
    if (_localChanged(local, entry, file!) ||
        open.isPathOpen(local) ||
        engine.manifest.operationsAt(local).any((o) => o.kind != 'artifact')) {
      throw const CloudFailure(
        'Local changes or open copies need attention before moving.',
      );
    }
    await send!(file, to, parentId, selected['job'] as String?);
    return 'Moved $path to ${parent.isEmpty ? "the library root" : parent}.';
  }
}
