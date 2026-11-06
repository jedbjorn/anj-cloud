// Disk-backed conditional test fixture, never a gateway or production transport.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';

class FixtureCloud implements CloudApi {
  FixtureCloud(this.root) {
    root.createSync(recursive: true);
  }
  final Directory root;
  File file(String path) {
    validateRelative(path);
    return File(p.join(root.path, path));
  }

  Future<String> version(File file) async =>
      '"${await sha256.bind(file.openRead()).first}"';
  @override
  Future<List<RemoteItem>> snapshot() async {
    final result = <RemoteItem>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final path = p.relative(entity.path, from: root.path);
      if (entity is Directory) {
        result.add(RemoteItem(path, ItemKind.directory, '"directory-$path"'));
      }
      if (entity is File) {
        result.add(
          RemoteItem(
            path,
            ItemKind.file,
            await version(entity),
            size: await entity.length(),
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async {
    final source = file(path);
    if (!source.existsSync() || await version(source) != etag) {
      throw const CloudFailure('fixture version changed', status: 412);
    }
    final sink = target.openWrite();
    try {
      await sink.addStream(source.openRead());
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  @override
  bool get lastUploadReadBack => false;
  @override
  int? get uploadLimit => null;

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    final target = file(path);
    final current = target.existsSync() ? await version(target) : null;
    if (current != etag) {
      throw const CloudFailure('fixture version changed', status: 412);
    }
    target.parent.createSync(recursive: true);
    await source.copy(target.path);
    return version(target);
  }

  @override
  Future<void> mkdir(String path) async {
    Directory(file(path).path).createSync(recursive: true);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    final target = file(path);
    if (await version(target) != etag) {
      throw const CloudFailure('fixture version changed', status: 412);
    }
    await target.delete();
  }

  @override
  Future<void> move(String from, String to, {required String etag}) async {
    final source = file(from);
    if (await version(source) != etag) {
      throw const CloudFailure('fixture version changed', status: 412);
    }
    await source.rename(file(to).path);
  }

  @override
  bool get safeFolderDeletion => false;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async => throw const CloudFailure('not qualified');
  @override
  Future<AddedPage?> addedSince(int after) async => null;
  @override
  void close() {}
}
