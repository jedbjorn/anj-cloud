import 'dart:io';

import '../state/model.dart';

/// One authenticated account's anj-cloud namespace. Implementations must fail
/// incomplete enumeration and preserve remote preconditions. ETags are opaque.
abstract interface class CloudApi {
  Future<List<RemoteItem>> snapshot();
  Future<void> download(String path, File target, {required String etag});
  Future<String> upload(String path, File source, {required String? etag});

  /// True when the version returned by the most recent [upload] was obtained
  /// by a separate read-back request rather than the upload response itself.
  /// Such a version may belong to a concurrent writer, so it never becomes
  /// evidence that this client's bytes are held by the server.
  bool get lastUploadReadBack;

  /// The largest upload the server accepts, as it last reported it (the
  /// `X-Anj-Upload-Limit` header on any response); null while unknown, and
  /// always for gateways that do not report one.
  int? get uploadLimit;
  Future<void> mkdir(String path);
  Future<void> deleteFile(String path, {required String etag});

  /// Renames the file or folder at [from] (still version [etag]) to the
  /// absent [to] in the same folder, never replacing an item there. Used for
  /// a rename that changes only case or Unicode normalization (SC-054), so
  /// the item, its versions and a folder's whole subtree move at once.
  Future<void> move(String from, String to, {required String etag});

  /// False until concurrent collection deletion has direct integration proof.
  bool get safeFolderDeletion;
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  });

  /// The gateway's added times recorded after [after] (spec #24). Null when
  /// the server has no such record (an older gateway): New then has no dates.
  Future<AddedPage?> addedSince(int after);
  void close();
}

class DisconnectedCloud implements CloudApi {
  const DisconnectedCloud();
  Never unavailable() => throw const CloudFailure(
    'Pair this device to connect. Local changes are retained.',
  );
  @override
  Future<List<RemoteItem>> snapshot() async => unavailable();
  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async => unavailable();
  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async => unavailable();
  @override
  bool get lastUploadReadBack => false;
  @override
  int? get uploadLimit => null;
  @override
  Future<void> mkdir(String path) async => unavailable();
  @override
  Future<void> move(String from, String to, {required String etag}) async =>
      unavailable();
  @override
  Future<void> deleteFile(String path, {required String etag}) async =>
      unavailable();
  @override
  bool get safeFolderDeletion => false;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async => unavailable();
  @override
  Future<AddedPage?> addedSince(int after) async => unavailable();
  @override
  void close() {}
}
