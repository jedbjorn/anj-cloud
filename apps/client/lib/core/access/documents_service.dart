import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../local/root_tree.dart' show uniqueId;
import '../ports/documents.dart';
import '../sync/top_folders.dart';
import 'access_store.dart';

/// Who is calling the provider, as the platform established it.
enum CallerKind {
  /// This app itself.
  own,

  /// The system document UI (holds MANAGE_DOCUMENTS): the Files app and the
  /// picker, acting on the user's direct choices.
  system,

  /// An app holding a per-document grant for exactly this document: a file
  /// opened from our app, tapped in the Files app or picked one at a time
  /// (spec #28 R1). It reaches that one document only.
  document,

  /// Any other app: it reaches a folder only when the user approved it for
  /// that folder in "Apps with access" (decision #127), whatever it picked.
  app,
}

class DocumentsCaller {
  const DocumentsCaller(
    this.kind, {
    this.package,
    this.documentRead = false,
    this.documentWrite = false,
  });
  factory DocumentsCaller.fromMap(Map<Object?, Object?> value) =>
      DocumentsCaller(
        CallerKind.values.byName(value['kind'] as String),
        package: value['package'] as String?,
        documentRead: value['documentRead'] == true,
        documentWrite: value['documentWrite'] == true,
      );
  final CallerKind kind;
  final String? package;
  final bool documentRead;
  final bool documentWrite;
}

/// Platform grant housekeeping after a revoke (Android: the persisted tree
/// grants of the provider and `revokeUriPermission(package, uri, flags)`).
abstract interface class GrantRevoker {
  /// Tree document ids that currently hold persisted grants.
  Future<List<String>> persistedTrees();

  /// Withdraws [package]'s grant on the tree of [documentId].
  Future<void> revokeTree(String package, String documentId);

  /// Persisted single-document grants (not trees), one per grant: the
  /// document id and whether it allows reading and writing (spec #28 R1).
  Future<List<({String id, bool read, bool write})>> persistedDocuments();

  /// Withdraws every app's grant on the single document [documentId].
  Future<void> revokeDocument(String documentId);
}

/// The AnJ Cloud documents provider's decisions (spec #28 A5, decision
/// #127), in shared Dart so the allowlist is enforced and tested in one
/// place. The runner's provider forwards every call here with the caller the
/// platform identified; listings come from the engine's projection
/// ([DocumentsHost.entries]); every change goes to the sync worker as a
/// command. Nothing here reads the manifest or writes the root.
///
/// Rules:
/// - Default: no app has access. An [CallerKind.app] caller reaches a path
///   only through a non-revoked approval of its package for that path's
///   folder or an ancestor, read-write for any change.
/// - Changes are made *inside* approved folders: create needs the parent
///   approved; rename, move and delete need the item's parent approved, so an
///   app cannot rename, move or delete the folder it was approved for.
/// - Approvals of a folder and of a subfolder are separate rows: each covers
///   its own subtree, and revoking one leaves the other.
/// - Working copies (`w:` ids) are reachable only by per-document grants.
class DocumentsService extends ChangeNotifier implements AppAccess {
  DocumentsService(
    this.host,
    this.store, {
    this.revoker,
    this.platformApps,
    DateTime Function()? clock,
    this.pruneGrace = const Duration(minutes: 5),
  }) : clock = clock ?? DateTime.now {
    host.addListener(_projectionChanged);
    host.onLocalRename = localRenamed;
    _projectionChanged();
  }

  final DocumentsHost host;
  final AccessStore store;
  final GrantRevoker? revoker;
  final PlatformApps? platformApps;
  final DateTime Function() clock;
  final Duration pruneGrace;

  /// Called with the document ids whose children changed.
  void Function(List<String> ids)? onChildrenChanged;

  /// Called after every change another app made through the provider
  /// (create, rename, move, delete, and closing a file it opened for
  /// writing): Android asks for prompt background work, so the change
  /// uploads although our app is not on screen and its process would be
  /// frozen (spec #28 Background Sync, review M1).
  void Function()? onLocalChange;

  void _localChange() {
    try {
      onLocalChange?.call();
    } catch (_) {
      // The periodic run picks the change up all the same.
    }
  }

  static const rootId = 'root';

  // ---- projection ----------------------------------------------------------

  Map<String, Map<String, dynamic>> _byPath = {};
  Map<String, List<String>> _children = {};
  Map<String, String> _signature = {};
  Map<String, String> _working = {}; // staged basename -> entry path
  bool _ready = false;

  bool get ready => _ready;

  static bool visible(Map<String, dynamic> entry) {
    final status = entry['status'] as String? ?? '';
    final kind = entry['kind'];
    return (kind == 'file' || kind == 'directory') &&
        !status.startsWith('delete') &&
        status != 'removed locally';
  }

  void _projectionChanged() {
    final byPath = <String, Map<String, dynamic>>{};
    final children = <String, List<String>>{};
    final working = <String, String>{};
    final shown = <String, Map<String, dynamic>>{};
    for (final entry in host.entries) {
      final path = entry['path'] as String;
      for (final copy in (entry['workingCopies'] as List? ?? const [])) {
        final staged = (copy as Map)['path'];
        if (staged is String) working[p.basename(staged)] = path;
      }
      if (visible(entry)) shown[path] = entry;
    }
    // The provider's own changes show at once; the projection catches up
    // at the next pass, and each overlay row ends when it agrees.
    final now = clock();
    _overlay.removeWhere(
      (path, change) =>
          now.difference(change.at) > pruneGrace ||
          (change.entry == null
              ? !shown.containsKey(path)
              : shown.containsKey(path)),
    );
    for (final MapEntry(:key, :value) in _overlay.entries) {
      if (value.entry == null) {
        shown.remove(key);
      } else {
        shown[key] = value.entry!;
      }
    }
    for (final MapEntry(key: path, value: entry) in shown.entries) {
      byPath[path] = entry;
      children.putIfAbsent(_parent(path), () => []).add(path);
    }
    for (final list in children.values) {
      list.sort();
    }
    final signature = {
      for (final MapEntry(:key, :value) in children.entries)
        key: [
          for (final path in value)
            '$path|${byPath[path]!['kind']}|${byPath[path]!['size']}|'
                '${byPath[path]!['etag']}|${byPath[path]!['expectedPresent']}',
        ].join('\n'),
    };
    final changed = <String>{
      for (final key in {...signature.keys, ..._signature.keys})
        if (signature[key] != _signature[key]) key,
    };
    final wasReady = _ready;
    _byPath = byPath;
    _children = children;
    _signature = signature;
    _working = working;
    _ready = host.documentsReady;
    if (_ready) {
      final ended = [
        ...store.prune(byPath.keys.toSet(), grace: pruneGrace),
        ..._rebind(byPath),
      ];
      if (ended.isNotEmpty) {
        _approvalCache = null;
        unawaited(_withdraw(ended));
      }
    }
    final ids = <String>[
      if (_ready != wasReady) rootId,
      for (final path in changed) ?_existingId(path),
    ];
    if (ids.isNotEmpty) onChildrenChanged?.call(ids.toSet().toList());
    notifyListeners();
  }

  /// Approvals bind to a folder's path and its local identity (review F3).
  /// A rename or move through the provider or the app keeps both (the id
  /// follows, the inode is the same). Where a *different* folder now sits
  /// at an approved path (it was replaced on another device and downloaded
  /// again, or deleted and recreated), the approval ends rather than being
  /// inherited. A folder renamed on another device shows here as a removal
  /// and a new folder: its approval ends after the prune grace (fail
  /// closed) and the user approves the new name.
  List<StoredApproval> _rebind(Map<String, Map<String, dynamic>> byPath) {
    final ended = <StoredApproval>[];
    for (final approval in _approvals()) {
      if (approval.folder.isEmpty) continue;
      final identity = byPath[approval.folder]?['localIdentity'];
      if (identity is! String) continue;
      final bound = store.identityOf(approval.folderId);
      if (bound == null) {
        store.bindIdentity(approval.folderId, identity);
      } else if (bound != identity) {
        ended.addAll(store.forget(approval.folder));
      }
    }
    return ended;
  }

  /// The app itself renamed or moved [from] to [to] (the Rename action of a
  /// name other devices cannot hold): ids and approvals follow, as for a
  /// provider rename.
  void localRenamed(String from, String to) {
    store.move(from, to);
    _approvalCache = null;
    _projectionChanged();
  }

  /// Items this service created, moved or deleted that the projection does
  /// not show yet: a row to list ([entry]) or a row to hide (null).
  final Map<String, ({DateTime at, Map<String, dynamic>? entry})> _overlay = {};

  void _show(String path, Map<String, dynamic> entry) =>
      _overlay[path] = (at: clock(), entry: {...entry, 'path': path});
  void _hide(String path) => _overlay[path] = (at: clock(), entry: null);

  static String _parent(String path) {
    final parent = p.posix.dirname(path);
    return parent == '.' ? '' : parent;
  }

  String? _existingId(String path) {
    if (path.isEmpty) return rootId;
    if (!_byPath.containsKey(path)) return null;
    return 'n:${store.idFor(path)}';
  }

  String idOf(String path) => path.isEmpty ? rootId : 'n:${store.idFor(path)}';

  /// The library path of [id], or a working-copy reference.
  ({String? path, String? working}) resolve(String id) {
    if (id == rootId) return (path: '', working: null);
    if (id.startsWith('n:')) {
      final number = int.tryParse(id.substring(2));
      final path = number == null ? null : store.pathOf(number);
      if (path == null || !_byPath.containsKey(path)) {
        throw const DocumentsFailure('notFound', 'This item no longer exists.');
      }
      return (path: path, working: null);
    }
    if (id.startsWith('w:')) {
      final name = id.substring(2);
      if (!_working.containsKey(name)) {
        throw const DocumentsFailure(
          'notFound',
          'This working copy was finished or removed.',
        );
      }
      return (path: null, working: name);
    }
    throw const DocumentsFailure('notFound', 'Unknown document.');
  }

  // ---- access --------------------------------------------------------------

  static bool covers(String folder, String path) =>
      folder.isEmpty || path == folder || path.startsWith('$folder/');

  /// The approval that lets an app caller [write] or read [path], or a
  /// refusal. The most specific approval is the one marked connected.
  StoredApproval _approved(DocumentsCaller caller, String path, bool write) {
    final package = caller.package;
    if (package == null) {
      throw const DocumentsFailure(
        'denied',
        'AnJ Cloud could not identify the calling app.',
      );
    }
    StoredApproval? best;
    for (final approval in _approvals()) {
      if (approval.package != package ||
          approval.revoked ||
          !covers(approval.folder, path) ||
          (write && approval.mode != AccessMode.write)) {
        continue;
      }
      if (best == null || approval.folder.length > best.folder.length) {
        best = approval;
      }
    }
    if (best == null) {
      final folder = _byPath[path]?['kind'] == 'directory' || path.isEmpty
          ? path
          : _parent(path);
      store.request(package, folder);
      notifyListeners();
      throw DocumentsFailure(
        'denied',
        write
            ? 'AnJ Cloud has not given this app permission to change files here.'
            : 'AnJ Cloud has not given this app access to this folder. '
                  'Approve it in AnJ Cloud: Apps with access.',
      );
    }
    _seen(best);
    return best;
  }

  List<StoredApproval>? _approvalCache;
  List<StoredApproval> _approvals() => _approvalCache ??= store.approvals();
  void _approvalsChanged() {
    _approvalCache = null;
    notifyListeners();
  }

  final Map<String, DateTime> _lastSeenWrite = {};
  void _seen(StoredApproval approval) {
    final key = '${approval.package}\n${approval.folderId}';
    final now = clock();
    final previous = _lastSeenWrite[key];
    if (approval.lastSeen != null &&
        previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      return;
    }
    _lastSeenWrite[key] = now;
    store.seen(approval.package, approval.folderId, now);
    _approvalsChanged();
  }

  final Map<String, DateTime> _lastFileUse = {};

  /// Remembers which app uses a single-document grant, so "Apps with
  /// access" can name it (the platform's grant list does not; review M2).
  void _fileUsed(String id, DocumentsCaller caller) {
    final package = caller.package;
    if (caller.kind != CallerKind.document || package == null) return;
    final key = '$id\n$package';
    final now = clock();
    final previous = _lastFileUse[key];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      return;
    }
    _lastFileUse[key] = now;
    try {
      store.fileUsed(id, package, now);
    } catch (_) {
      // A label is a nicety; the call itself goes on.
    }
  }

  /// Read access to the library item [path].
  void _read(DocumentsCaller caller, String path) {
    switch (caller.kind) {
      case CallerKind.own || CallerKind.system:
        return;
      case CallerKind.document:
        // A per-document grant never hides a folder approval (review F4).
        if (!caller.documentRead) _approved(caller, path, false);
      case CallerKind.app:
        _approved(caller, path, false);
    }
  }

  /// Change access inside the folder [folder].
  void _change(DocumentsCaller caller, String folder) {
    switch (caller.kind) {
      case CallerKind.own || CallerKind.system:
        return;
      case CallerKind.document || CallerKind.app:
        // A per-document grant cannot change its folder; a folder approval
        // of the same app still can.
        _approved(caller, folder, true);
    }
  }

  bool _canWrite(DocumentsCaller caller, String folder) {
    switch (caller.kind) {
      case CallerKind.own || CallerKind.system:
        return true;
      case CallerKind.document || CallerKind.app:
        return _approvals().any(
          (a) =>
              a.package == caller.package &&
              !a.revoked &&
              a.mode == AccessMode.write &&
              covers(a.folder, folder),
        );
    }
  }

  // ---- provider calls ------------------------------------------------------

  Map<String, Object?> roots() => {
    'ready': _ready,
    'rootId': rootId,
    'files': _byPath.length,
  };

  Map<String, Object?> _row(String path, DocumentsCaller caller) {
    if (path.isEmpty) {
      return {
        'id': rootId,
        'name': null,
        'kind': 'directory',
        'create': _ready && _canWrite(caller, ''),
      };
    }
    final entry = _byPath[path]!;
    final directory = entry['kind'] == 'directory';
    final viewOnly = entry['viewOnly'] == true;
    final present = entry['expectedPresent'] == true;
    final mount = entry['incomingMount'] == true;
    final inside = !viewOnly && _canWrite(caller, path);
    // Documents, Music and Videos are never deleted, renamed or moved
    // (spec #34 P7): the provider does not offer it.
    final change =
        !viewOnly &&
        !mount &&
        !isTopFolder(path) &&
        _canWrite(caller, _parent(path));
    final modified = entry['remoteModified'];
    return {
      'id': idOf(path),
      'name': p.posix.basename(path),
      'kind': directory ? 'directory' : 'file',
      'size': directory ? null : entry['size'],
      'modified': modified is int ? modified * 1000 : null,
      'write': !directory && inside,
      'create': directory && inside && present,
      'delete': change,
      'rename': change && present,
      'move': change && present,
      'cloudOnly': !directory && !present,
    };
  }

  Map<String, Object?> document(String id, DocumentsCaller caller) {
    _fileUsed(id, caller);
    final target = resolve(id);
    if (target.working != null) {
      _workingAccess(caller, write: false);
      final path = _working[target.working]!;
      return {
        'id': id,
        'name': p.posix.basename(path),
        'kind': 'file',
        'size': null,
        'write': caller.kind != CallerKind.document || caller.documentWrite,
      };
    }
    _read(caller, target.path!);
    return _row(target.path!, caller);
  }

  Map<String, Object?> children(String id, DocumentsCaller caller) {
    if (!_ready) return {'loading': true, 'rows': const []};
    final target = resolve(id);
    if (target.working != null) {
      throw const DocumentsFailure('notFound', 'Not a folder.');
    }
    final path = target.path!;
    if (path.isNotEmpty && _byPath[path]!['kind'] != 'directory') {
      throw const DocumentsFailure('notFound', 'Not a folder.');
    }
    if (caller.kind == CallerKind.document) {
      throw const DocumentsFailure('denied', 'No access to this folder.');
    }
    _read(caller, path);
    final paths = _children[path] ?? const [];
    store.idsFor(paths);
    return {
      'loading': false,
      'rows': [for (final child in paths) _row(child, caller)],
    };
  }

  /// Whether [id] is [parent] or beneath it (tree grants; working copies are
  /// never part of a tree).
  bool isChild(String parent, String id) {
    try {
      final a = resolve(parent);
      final b = resolve(id);
      if (a.path == null || b.path == null) return false;
      return a.path != b.path && covers(a.path!, b.path!);
    } on DocumentsFailure {
      return false;
    }
  }

  void _workingAccess(DocumentsCaller caller, {required bool write}) {
    switch (caller.kind) {
      case CallerKind.own || CallerKind.system:
        return;
      case CallerKind.document:
        if (caller.documentRead && (!write || caller.documentWrite)) return;
      case CallerKind.app:
        break;
    }
    throw const DocumentsFailure(
      'denied',
      'Working copies open only through AnJ Cloud.',
    );
  }

  int _openCount = 0;

  /// Open descriptors handed out, by token (for the settings' open counts).
  final Map<String, ({String? package, String path, bool write})> _open = {};

  int openCount(String package, String folder) => _open.values
      .where((o) => o.package == package && covers(folder, o.path))
      .length;

  /// Opens [id] in [mode] (`r`, `w`, `rw`, `wt`, `wa`, `rwt`). Returns the
  /// worker's descriptor (`fd`) and a `token` the runner reports on close.
  Future<Map<String, Object?>> open(
    String id,
    String mode,
    DocumentsCaller caller,
  ) async {
    final write = mode.contains('w') || mode.contains('a');
    _fileUsed(id, caller);
    final target = resolve(id);
    final String path;
    if (target.working != null) {
      _workingAccess(caller, write: write);
      path = _working[target.working]!;
    } else {
      path = target.path!;
      if (path.isEmpty || _byPath[path]!['kind'] != 'file') {
        throw const DocumentsFailure('notFound', 'Not a file.');
      }
      switch (caller.kind) {
        case CallerKind.document:
          if (!caller.documentRead || (write && !caller.documentWrite)) {
            _approved(caller, path, write);
          }
        case CallerKind.app:
          _approved(caller, path, write);
        case CallerKind.own || CallerKind.system:
          break;
      }
      if (write && _byPath[path]!['viewOnly'] == true) {
        throw const DocumentsFailure(
          'readOnly',
          'This file is shared with you as View only.',
        );
      }
    }
    final token = 'open-${++_openCount}-${uniqueId()}';
    final result = await host.documentsCommand('open', {
      'path': target.working == null ? path : null,
      'working': target.working,
      'write': write,
      'token': token,
    });
    _open[token] = (package: caller.package, path: path, write: write);
    notifyListeners();
    return {...result, 'token': token};
  }

  /// The runner reports that the other app closed descriptor [token].
  Future<void> closed(String token) async {
    final open = _open.remove(token);
    if (open == null) return;
    notifyListeners();
    await host.documentsCommand('closed', {'token': token});
    // A descriptor opened for writing may have changed the file.
    if (open.write) _localChange();
  }

  Future<String> create(
    String parentId,
    String name,
    bool directory,
    DocumentsCaller caller,
  ) async {
    final parent = resolve(parentId).path;
    if (parent == null ||
        (parent.isNotEmpty && _byPath[parent]!['kind'] != 'directory')) {
      throw const DocumentsFailure('notFound', 'Not a folder.');
    }
    _change(caller, parent);
    final result = await host.documentsCommand('create', {
      'parent': parent,
      'name': name,
      'directory': directory,
    });
    final path = result['path'] as String;
    _show(path, {
      'kind': directory ? 'directory' : 'file',
      'size': 0,
      'status': 'queued',
      'expectedPresent': true,
    });
    _projectionChanged();
    _localChange();
    return idOf(path);
  }

  Future<String> rename(String id, String name, DocumentsCaller caller) async {
    final path = _library(id);
    _change(caller, _parent(path));
    final result = await host.documentsCommand('rename', {
      'path': path,
      'name': name,
    });
    return _moved(path, result['path'] as String);
  }

  Future<String> move(
    String id,
    String targetParentId,
    DocumentsCaller caller,
  ) async {
    final path = _library(id);
    final target = resolve(targetParentId).path;
    if (target == null ||
        (target.isNotEmpty && _byPath[target]!['kind'] != 'directory')) {
      throw const DocumentsFailure('notFound', 'Not a folder.');
    }
    _change(caller, _parent(path));
    _change(caller, target);
    final result = await host.documentsCommand('move', {
      'path': path,
      'parent': target,
    });
    return _moved(path, result['path'] as String);
  }

  String _moved(String from, String to) {
    store.move(from, to);
    for (final MapEntry(key: path, value: entry) in _byPath.entries.toList()) {
      if (!covers(from, path)) continue;
      _hide(path);
      _show('$to${path.substring(from.length)}', {
        ...entry,
        'etag': null,
        'status': 'queued',
      });
    }
    _approvalCache = null;
    _projectionChanged();
    _localChange();
    return idOf(to);
  }

  Future<void> delete(String id, DocumentsCaller caller) async {
    final path = _library(id);
    _change(caller, _parent(path));
    await host.documentsCommand('delete', {'path': path});
    for (final known in _byPath.keys.toList()) {
      if (covers(path, known)) _hide(known);
    }
    final ended = store.forget(path);
    _approvalCache = null;
    _projectionChanged();
    _localChange();
    await _withdraw(ended);
  }

  String _library(String id) {
    final path = resolve(id).path;
    if (path == null || path.isEmpty) {
      throw const DocumentsFailure(
        'refused',
        'This item cannot be changed here.',
      );
    }
    return path;
  }

  // ---- Apps with access ------------------------------------------------------

  @override
  List<AppApproval> get approvals => [
    for (final a in _approvals())
      AppApproval(
        package: a.package,
        folder: a.folder,
        mode: a.mode,
        status: a.revoked
            ? ApprovalStatus.revoked
            : a.lastSeen == null
            ? ApprovalStatus.approved
            : ApprovalStatus.connected,
        approvedAt: a.approvedAt,
        lastSeen: a.lastSeen,
        revokedAt: a.revokedAt,
        openFiles: openCount(a.package, a.folder),
      ),
  ];

  @override
  List<AccessRequest> get requests {
    final approved = {
      for (final a in _approvals())
        if (!a.revoked) '${a.package}\n${a.folder}',
    };
    return [
      for (final r in store.requests())
        if (!approved.contains('${r.package}\n${r.folder}')) r,
    ];
  }

  @override
  List<String> get folders => [
    '',
    for (final MapEntry(:key, :value) in _byPath.entries)
      if (value['kind'] == 'directory') key,
  ]..sort();

  @override
  Future<void> approve(String package, String folder, AccessMode mode) async {
    if (folder.isNotEmpty && _byPath[folder]?['kind'] != 'directory') {
      throw const DocumentsFailure('notFound', 'Choose an existing folder.');
    }
    store.approve(package, folder, mode);
    _approvalsChanged();
  }

  @override
  Future<void> revoke(String package, String folder) async {
    final ended = _approvals()
        .where((a) => a.package == package && a.folder == folder && !a.revoked)
        .toList();
    store.revoke(package, folder);
    _approvalsChanged();
    await _withdraw(ended);
  }

  @override
  Future<void> forget(String package, String folder) async {
    final ended = _approvals()
        .where((a) => a.package == package && a.folder == folder && !a.revoked)
        .toList();
    store.remove(package, folder);
    _approvalsChanged();
    await _withdraw(ended);
  }

  /// Withdraws the platform tree grants these approvals no longer justify:
  /// every persisted tree of the app's that no remaining approval of the app
  /// overlaps (the folder itself, a subfolder grant, which is a separate
  /// URI, or a parent the app picked). The allowlist already refuses the
  /// calls; this keeps the platform's grant list honest.
  Future<void> _withdraw(List<StoredApproval> ended) async {
    final revoker = this.revoker;
    if (revoker == null || ended.isEmpty) return;
    final List<String> trees;
    try {
      trees = await revoker.persistedTrees();
    } catch (_) {
      return;
    }
    for (final package in ended.map((a) => a.package).toSet()) {
      final remaining = _approvals()
          .where((a) => a.package == package && !a.revoked)
          .map((a) => a.folder)
          .toList();
      for (final tree in trees) {
        String? path;
        try {
          path = resolve(tree).path;
        } on DocumentsFailure {
          path = null; // the folder is gone: nothing can justify the grant
        }
        final overlapping =
            path != null &&
            remaining.any(
              (folder) => covers(folder, path!) || covers(path, folder),
            );
        if (overlapping) continue;
        try {
          await revoker.revokeTree(package, tree);
        } catch (_) {
          // Best effort: the provider refuses the app either way.
        }
      }
    }
  }

  /// Persisted single-file grants (spec #28 R1), listed so the user sees
  /// and can withdraw every grant an app keeps (review M2).
  @override
  Future<List<FileGrant>> fileGrants() async {
    final revoker = this.revoker;
    if (revoker == null) return const [];
    final grants = await revoker.persistedDocuments();
    final users = store.fileUsers();
    final byId = <String, List<({String id, bool read, bool write})>>{};
    for (final grant in grants) {
      (byId[grant.id] ??= []).add(grant);
    }
    final rows = [
      for (final MapEntry(key: id, value: held) in byId.entries)
        FileGrant(
          documentId: id,
          name: _fileName(id),
          holders: held.length,
          write: held.any((g) => g.write),
          packages: users[id] ?? const [],
        ),
    ];
    rows.sort((a, b) => a.name.compareTo(b.name));
    return rows;
  }

  String _fileName(String id) {
    try {
      final target = resolve(id);
      if (target.working != null) {
        return '${_working[target.working]} (being edited)';
      }
      return target.path!.isEmpty ? 'All of AnJ Cloud' : target.path!;
    } on DocumentsFailure {
      return 'A file that is no longer in AnJ Cloud';
    }
  }

  @override
  Future<void> revokeFile(String documentId) async {
    final revoker = this.revoker;
    if (revoker == null) return;
    await revoker.revokeDocument(documentId);
    store.forgetFileUsers(documentId);
    _lastFileUse.removeWhere((key, _) => key.startsWith('$documentId\n'));
    notifyListeners();
  }

  @override
  Future<List<InstalledApp>> installedApps() async =>
      await platformApps?.installedApps() ?? const [];

  @override
  Future<Map<String, InstalledApp>> describe(Iterable<String> packages) async =>
      await platformApps?.describe(packages.toList()) ?? const {};

  @override
  Future<bool> openApp(String package) async =>
      await platformApps?.openApp(package) ?? false;

  @override
  void dispose() {
    host.removeListener(_projectionChanged);
    if (host.onLocalRename == localRenamed) host.onLocalRename = null;
    super.dispose();
  }
}

/// The platform's app list and launcher for "Apps with access".
abstract interface class PlatformApps {
  Future<List<InstalledApp>> installedApps();
  Future<Map<String, InstalledApp>> describe(List<String> packages);
  Future<bool> openApp(String package);
}
