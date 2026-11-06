// Local moves by identity end to end (spec #33 I1, acceptance row 1): a real
// Linux sync engine against a review gateway and Nextcloud. Run by
// deploy/identity_move_fixture.py, which pairs the device and checks the
// moved file's version history in Nextcloud; this side proves what the
// client sends.
//
//   dart run tool/identity_move_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, certificate, key, work, folder}. Every request the
// engine makes through its cloud boundary is logged. Prints one JSON result
// line (claims, the request log of the moves, file IDs before and after);
// exits non-zero on the first failed claim.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

/// The worker's DAV client with every namespace and transfer request logged.
class _Logged implements CloudApi {
  _Logged(this.inner);
  final CloudApi inner;
  final log = <String>[];

  @override
  Future<List<RemoteItem>> snapshot() {
    log.add('PROPFIND (listing)');
    return inner.snapshot();
  }

  @override
  Future<void> download(String path, File target, {required String etag}) {
    log.add('GET $path');
    return inner.download(path, target, etag: etag);
  }

  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    log.add('PUT $path');
    return inner.upload(path, source, etag: etag);
  }

  @override
  bool get lastUploadReadBack => inner.lastUploadReadBack;
  @override
  int? get uploadLimit => inner.uploadLimit;

  @override
  Future<void> mkdir(String path) {
    log.add('MKCOL $path');
    return inner.mkdir(path);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    log.add('DELETE $path');
    return inner.deleteFile(path, etag: etag);
  }

  @override
  Future<void> move(String from, String to, {required String etag}) {
    log.add('MOVE $from -> $to');
    return inner.move(from, to, etag: etag);
  }

  @override
  bool get safeFolderDeletion => inner.safeFolderDeletion;

  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) {
    log.add('DELETE $path/');
    return inner.deleteFolder(path, versions: versions);
  }

  @override
  Future<AddedPage?> addedSince(int after) => inner.addedSince(after);

  @override
  void close() => inner.close();
}

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(config['work'] as String);
  if (work.existsSync()) throw StateError('Fixture work path must be absent.');
  work.createSync(recursive: true);
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(config['ca'] as String)
    ..useCertificateChain(config['certificate'] as String)
    ..usePrivateKey(config['key'] as String);
  // As the worker builds it (folder deletion qualified), so the old
  // behaviour (a delete plus a re-upload) would be sent and logged.
  final dav = DavCloud(
    Uri.parse(config['origin'] as String),
    context,
    folderDeletionQualified: true,
  );
  final cloud = _Logged(dav);
  final tree = RootTree.setup(
    (Directory('${work.path}/files')..createSync()).path,
    'identity-e2e',
    NativeRootFs(),
  );
  final store = Manifest(Directory('${work.path}/profile'))
    ..setSetting('retention', 'local');
  final engine = SyncEngine(store, tree, cloud);
  final folder = config['folder'] as String;
  final result = <String, Object?>{};
  final claims = <String, Object?>{};
  result['claims'] = claims;
  void claim(String name, bool passed, [Object? detail]) {
    claims[name] = detail ?? passed;
    if (!passed) {
      stdout.writeln(jsonEncode({'failed': name, ...result}));
      exit(1);
    }
  }

  String at(String name) => '${tree.root.path}/$folder/$name';
  void write(String name, String text) => File(at(name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text, flush: true);
  // Server items under the folder: relative path -> (file ID, version).
  Future<Map<String, (int?, String)>> server() async => {
    for (final item in await dav.snapshot())
      if (item.path.startsWith('$folder/'))
        item.path.substring(folder.length + 1): (item.fileId, item.etag),
  };
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await engine.tick();
    }
  }

  String status(String name) => store.entries['$folder/$name']!.status;

  try {
    await engine.tick();
    claim('folder synced down', Directory(at('')).existsSync());
    write('Photos/2026/Trip/a.jpg', 'a');
    write('Photos/2026/Trip/deep/b.jpg', 'b');
    write('Photos/2026/Trip/deep/deeper/c.jpg', 'c');
    write('Photos/2026/d.jpg', 'd');
    write('Docs/report.txt', 'report v1');
    write('Archive/keep.txt', 'keep');
    await settle();
    // A second version of the report, so Nextcloud keeps one in its history.
    write('Docs/report.txt', 'report v2');
    await settle();
    final before = await server();
    claim(
      'uploaded',
      before.keys.toSet().containsAll([
        'Photos/2026/Trip/deep/deeper/c.jpg',
        'Docs/report.txt',
        'Archive/keep.txt',
      ]),
      before.keys.toList()..sort(),
    );
    result['reportFileId'] = before['Docs/report.txt']!.$1;

    // Three top items: a file renamed into another folder, a deep subtree
    // moved to another parent, and a folder renamed in place.
    final renames = {
      'Docs/report.txt': 'Archive/Report 2026.txt',
      'Photos/2026/Trip': 'Archive/Trip 2026',
      'Photos': 'Pictures',
    };
    File(at('Docs/report.txt')).renameSync(at('Archive/Report 2026.txt'));
    Directory(at('Photos/2026/Trip')).renameSync(at('Archive/Trip 2026'));
    Directory(at('Photos')).renameSync(at('Pictures'));
    cloud.log.clear();
    await settle();
    final requests = [
      for (final line in cloud.log)
        if (!line.startsWith('PROPFIND')) line.replaceAll('$folder/', ''),
    ];
    result['requests'] = requests;
    result['listings'] = cloud.log
        .where((l) => l.startsWith('PROPFIND'))
        .length;
    claim(
      'one MOVE per top item, nothing else sent',
      // The subtree moved out of the renamed folder moves after it, from
      // the folder's new name.
      requests.length == 3 &&
          requests.toSet().containsAll([
            'MOVE Docs/report.txt -> Archive/Report 2026.txt',
            'MOVE Photos -> Pictures',
            'MOVE Pictures/2026/Trip -> Archive/Trip 2026',
          ]),
      requests,
    );
    claim(
      'no PUT, GET, MKCOL or DELETE',
      !requests.any(
        (r) =>
            r.startsWith('PUT') ||
            r.startsWith('GET') ||
            r.startsWith('MKCOL') ||
            r.startsWith('DELETE'),
      ),
    );
    final after = await server();
    String moved(String path) {
      for (final e in renames.entries) {
        if (path == e.key || path.startsWith('${e.key}/')) {
          return '${e.value}${path.substring(e.key.length)}';
        }
      }
      return path;
    }

    final ids = {
      for (final e in before.entries)
        e.key: {'before': e.value.$1, 'after': after[moved(e.key)]?.$1},
    };
    result['fileIds'] = ids;
    claim(
      'every item keeps its file ID at its new path',
      before.keys.every(
        (path) =>
            after[moved(path)]?.$1 != null &&
            after[moved(path)]!.$1 == before[path]!.$1,
      ),
      ids,
    );
    claim(
      'the old paths are gone from the cloud',
      renames.keys.every((path) => !after.containsKey(path)) &&
          after.length == before.length,
      after.keys.toList()..sort(),
    );
    claim(
      'rows current at the new paths, none left at the old',
      [
            'Archive/Report 2026.txt',
            'Archive/Trip 2026/deep/deeper/c.jpg',
            'Pictures/2026/d.jpg',
          ].every((n) => status(n) == 'current local') &&
          !store.entries.keys.any(
            (k) =>
                k.startsWith('$folder/Photos') ||
                k.startsWith('$folder/Docs/report'),
          ),
    );
    claim(
      'contents unchanged on disk',
      File(at('Archive/Report 2026.txt')).readAsStringSync() == 'report v2' &&
          File(at('Archive/Trip 2026/deep/deeper/c.jpg')).readAsStringSync() ==
              'c',
    );
    stdout.writeln(jsonEncode(result));
  } finally {
    engine.close();
  }
}
