import 'dart:async';
import 'dart:io';

import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/gateway/fetch_api.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';

class FakeCloud implements CloudApi {
  final Map<String, List<int>> files = {};
  final Map<String, String> versions = {};
  final Set<String> directories = {};
  bool online = true;
  bool failUpload = false;
  bool loseNextUploadAcknowledgement = false;

  /// Simulates a PUT response without a version, read back separately.
  bool readBackUploadVersion = false;
  @override
  bool lastUploadReadBack = false;
  @override
  int? uploadLimit;

  /// Thrown by every upload while set (after counting the attempt).
  Object? uploadError;

  /// Upload calls made, successful or not.
  int uploadAttempts = 0;
  int counter = 0;
  int deletes = 0;
  int uploads = 0;
  int completedDownloads = 0;
  int failDownloads = 0;
  bool foldersQualified = false;

  /// Listing metadata (spec #24). File IDs are assigned on first put/upload.
  final Map<String, int> fileIds = {};
  final Map<String, int> modified = {};
  int nextFileId = 100;

  /// The gateway's added times; null models a gateway without the endpoint.
  Map<int, int>? added;
  int addedFetches = 0;
  int addedPage = 1000;
  bool failAdded = false;
  final addedAfter = <int>[];

  /// The next request with a non-zero cursor answers `reset` (a replaced
  /// gateway registry).
  bool resetAdded = false;

  /// Stores every name in NFC and resolves any spelling to it, as Nextcloud
  /// does (decision #138).
  bool nfcOnly = false;
  String nfc(String path) => nfcOnly ? NamePolicy.nfc(path) : path;

  void check() {
    if (!online) throw const CloudFailure('offline fixture');
  }

  void put(String path, String text, {int? modifiedAt}) {
    path = nfc(path);
    files[path] = text.codeUnits;
    versions[path] = '"v${++counter}"';
    fileIds.putIfAbsent(path, () => ++nextFileId);
    if (modifiedAt != null) modified[path] = modifiedAt;
  }

  void remove(String path) {
    path = nfc(path);
    files.remove(path);
    versions.remove(path);
    fileIds.remove(path);
    modified.remove(path);
  }

  @override
  Future<List<RemoteItem>> snapshot() async {
    check();
    return [
      for (final d in directories)
        RemoteItem(d, ItemKind.directory, versions[d]!),
      for (final f in files.entries)
        RemoteItem(
          f.key,
          ItemKind.file,
          versions[f.key]!,
          size: f.value.length,
          fileId: fileIds[f.key],
          modified: modified[f.key],
        ),
    ];
  }

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async {
    check();
    path = nfc(path);
    if (failDownloads > 0) {
      failDownloads--;
      throw const CloudFailure('injected download failure');
    }
    if (versions[path] != etag) {
      throw const CloudFailure('changed', status: 412);
    }
    completedDownloads++;
    await target.writeAsBytes(files[path]!, flush: true);
  }

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    check();
    path = nfc(path);
    uploadAttempts++;
    lastUploadReadBack = readBackUploadVersion;
    if (uploadError case final error?) throw error;
    if (failUpload) throw const CloudFailure('injected I/O failure');
    if (versions[path] != etag) {
      throw const CloudFailure('changed', status: 412);
    }
    files[path] = await source.readAsBytes();
    versions[path] = '"v${++counter}"';
    fileIds.putIfAbsent(path, () => ++nextFileId);
    uploads++;
    if (loseNextUploadAcknowledgement) {
      loseNextUploadAcknowledgement = false;
      throw const CloudFailure('accepted upload; acknowledgement lost');
    }
    return versions[path]!;
  }

  @override
  Future<void> mkdir(String path) async {
    check();
    path = nfc(path);
    directories.add(path);
    versions[path] ??= '"v${++counter}"';
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    check();
    path = nfc(path);
    if (versions[path] != etag) {
      throw const CloudFailure('changed', status: 412);
    }
    deletes++;
    remove(path);
  }

  /// Moves made, successful or not.
  final moves = <String>[];

  @override
  Future<void> move(String from, String to, {required String etag}) async {
    check();
    from = nfc(from);
    to = nfc(to);
    moves.add('$from -> $to');
    if (versions[from] != etag) {
      throw const CloudFailure('changed', status: 412);
    }
    if (versions.containsKey(to)) {
      throw const CloudFailure('target exists', status: 412);
    }
    String renamed(String path) =>
        path == from ? to : '$to${path.substring(from.length)}';
    bool under(String path) => path == from || path.startsWith('$from/');
    for (final path in [...files.keys].where(under)) {
      files[renamed(path)] = files.remove(path)!;
      if (fileIds.remove(path) case final id?) fileIds[renamed(path)] = id;
      if (modified.remove(path) case final at?) modified[renamed(path)] = at;
    }
    for (final path in [...directories].where(under)) {
      directories
        ..remove(path)
        ..add(renamed(path));
    }
    for (final path in [...versions.keys].where(under)) {
      versions[renamed(path)] = versions.remove(path)!;
    }
  }

  @override
  bool get safeFolderDeletion => foldersQualified;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    throw const CloudFailure('folder fixture not qualified');
  }

  /// Pages ordered by file ID (the fake's cursor), [addedPage] rows each.
  @override
  Future<AddedPage?> addedSince(int after) async {
    check();
    addedFetches++;
    addedAfter.add(after);
    if (failAdded) throw const CloudFailure('injected added-time failure');
    final map = added;
    if (map == null) return null;
    if (resetAdded && after > 0) {
      resetAdded = false;
      return const AddedPage({}, cursor: 0, reset: true);
    }
    final ids = map.keys.where((id) => id > after).toList()..sort();
    final page = ids.take(addedPage).toList();
    return AddedPage(
      {for (final id in page) id: map[id]!},
      cursor: page.isEmpty ? after : page.last,
      more: ids.length > page.length,
    );
  }

  @override
  void close() {}
}

class MemorySecrets implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// A [FetchTransport] whose answers the test sets; records every call.
class FakeFetch implements FetchTransport {
  final calls = <String>[];
  List<FetchJob>? rows = const [];
  FetchError? listError;
  FetchError? actionError;
  List<FetchJob> submitted = const [];
  ({List<String> urls, FetchKind kind, FetchResolution? resolution})?
  lastSubmit;

  /// When set, the list waits for it (a list under way).
  Completer<void>? listGate;

  @override
  Future<List<FetchJob>?> listFetchJobs() async {
    calls.add('list');
    final gate = listGate;
    if (gate != null) await gate.future;
    final error = listError;
    if (error != null) throw FetchFailure(error);
    return rows;
  }

  @override
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  }) async {
    calls.add('submit');
    lastSubmit = (urls: urls, kind: kind, resolution: resolution);
    final error = actionError;
    if (error != null) throw FetchFailure(error);
    return submitted;
  }

  @override
  Future<void> deleteFetchJob(String id) async {
    calls.add('delete $id');
    final error = actionError;
    if (error != null) throw FetchFailure(error);
  }

  @override
  Future<void> clearFetchJobs() async {
    calls.add('clear');
    final error = actionError;
    if (error != null) throw FetchFailure(error);
  }
}

/// A job row in [state] (spec #42).
FetchJob fetchJob(String id, FetchState state, {DateTime? finished}) =>
    FetchJob(id: id, state: state, finished: finished);
