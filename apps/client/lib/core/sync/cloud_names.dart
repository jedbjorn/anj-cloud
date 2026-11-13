/// Cloud path <-> local path, one segment at a time (spec #49 Sync Boundary,
/// decision #199). The manifest is keyed by local spelling; a listed item
/// whose local name differs from its cloud name (R3, decision #138
/// normalization) carries its cloud segment. Every request leaves through
/// [NamedCloud], which maps each local segment back; an unknown local name
/// is literal (spec Reverse direction), so a local name never resolves to a
/// different cloud item.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../gateway/admin_api.dart';
import '../gateway/cloud_api.dart';
import '../gateway/sharing.dart';
import '../gateway/trash_api.dart';
import '../state/model.dart';

/// The two directions of the boundary, from the latest listing and the
/// manifest's recorded cloud names ([Entry.cloudName]).
class CloudNames {
  /// The recorded cloud name of the item at a local path; bound by the
  /// engine to its manifest so names survive a restart before a listing.
  String? Function(String local) recorded = (_) => null;

  /// Local path -> cloud name of its last segment, where they differ.
  Map<String, String> _cloudName = const {};

  /// Cloud path -> local path, where they differ.
  Map<String, String> _localPath = const {};

  /// Cloud name of the last segment of each listed local path, where it
  /// differs from the local one (test seam; the engine records them).
  Map<String, String> get listedCloudNames => _cloudName;

  /// The latest listing's differences, replacing the previous ones.
  void listed(Map<String, String> cloudNames, Map<String, String> localPaths) {
    _cloudName = cloudNames;
    _localPath = localPaths;
  }

  /// The cloud name of the item at [local]: from the listing, else as last
  /// recorded, else the local name itself.
  String cloudName(String local) =>
      _cloudName[local] ?? recorded(local) ?? p.posix.basename(local);

  /// [local] (root-relative) as a cloud path.
  String cloudPath(String local) {
    if (local.isEmpty || local == '.') return local;
    final segments = local.split('/');
    var prefix = '';
    final out = <String>[];
    for (final segment in segments) {
      prefix = prefix.isEmpty ? segment : '$prefix/$segment';
      out.add(cloudName(prefix));
    }
    return out.join('/');
  }

  /// The cloud path of the item at [from] once moved to [to] (local paths):
  /// a move that keeps the local name keeps the cloud name; a new local name
  /// is literal.
  String movedCloudPath(String from, String to) {
    final parent = p.posix.dirname(to);
    final name = p.posix.basename(from) == p.posix.basename(to)
        ? cloudName(from)
        : p.posix.basename(to);
    return parent == '.' ? name : '${cloudPath(parent)}/$name';
  }

  /// [cloud] (root-relative) as a local path: the deepest listed prefix,
  /// then the rest literal.
  String localPath(String cloud) {
    if (_localPath.isEmpty || cloud.isEmpty) return cloud;
    for (var at = cloud; at != '.'; at = p.posix.dirname(at)) {
      final local = _localPath[at];
      if (local != null) {
        return at == cloud ? local : '$local${cloud.substring(at.length)}';
      }
    }
    return cloud;
  }
}

/// Maps every path a request carries from local to cloud, and every path an
/// answer carries back (shares; a restore). Sits inside [ActivityCloud], so
/// transfers stay recorded under local paths. Trash listings stay cloud
/// paths: they are only shown, and shown names are cloud names.
class NamedCloud
    with ForwardSharing, ForwardAdmin, ForwardTrash
    implements CloudApi {
  NamedCloud(this.inner, this.names);
  final CloudApi inner;
  final CloudNames names;
  @override
  CloudApi get sharingTarget => inner;

  String _cloud(String path) => names.cloudPath(path);

  @override
  Future<List<RemoteItem>> snapshot() => inner.snapshot();
  @override
  Future<void> download(String path, File target, {required String etag}) =>
      inner.download(_cloud(path), target, etag: etag);
  @override
  Future<String> upload(String path, File source, {required String? etag}) =>
      inner.upload(_cloud(path), source, etag: etag);
  @override
  bool get lastUploadReadBack => inner.lastUploadReadBack;
  @override
  int? get uploadLimit => inner.uploadLimit;
  @override
  Future<void> mkdir(String path) => inner.mkdir(_cloud(path));
  @override
  Future<void> deleteFile(String path, {required String etag}) =>
      inner.deleteFile(_cloud(path), etag: etag);
  @override
  Future<void> move(String from, String to, {required String etag}) =>
      inner.move(_cloud(from), names.movedCloudPath(from, to), etag: etag);
  @override
  bool get safeFolderDeletion => inner.safeFolderDeletion;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) => inner.deleteFolder(
    _cloud(path),
    versions: {
      for (final MapEntry(:key, :value) in versions.entries) _cloud(key): value,
    },
  );
  @override
  Future<AddedPage?> addedSince(int after) => inner.addedSince(after);
  @override
  void close() => inner.close();

  IncomingShare _incoming(IncomingShare share) => IncomingShare(
    share.shareId,
    names.localPath(share.path),
    share.ownerName,
    share.permission,
    ownerUnavailable: share.ownerUnavailable,
  );

  OutgoingShare _outgoing(OutgoingShare share) => OutgoingShare(
    share.shareId,
    names.localPath(share.path),
    share.recipientId,
    share.recipientName,
    share.permission,
  );

  @override
  Future<List<IncomingShare>?> incomingShares() async =>
      (await super.incomingShares())?.map(_incoming).toList();
  @override
  Future<List<OutgoingShare>> outgoingShares() async =>
      (await super.outgoingShares()).map(_outgoing).toList();
  @override
  Future<OutgoingShare> createShare(
    String path,
    String recipientId,
    SharePermission permission,
  ) async =>
      _outgoing(await super.createShare(_cloud(path), recipientId, permission));
  @override
  Future<OutgoingShare> updateShare(
    String shareId,
    SharePermission permission,
  ) async => _outgoing(await super.updateShare(shareId, permission));
  @override
  Future<String?> renameForEveryone(String shareId, String name) async {
    final path = await super.renameForEveryone(shareId, name);
    return path == null ? null : names.localPath(path);
  }
}
