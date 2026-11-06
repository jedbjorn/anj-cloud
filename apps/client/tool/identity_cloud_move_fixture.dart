// Cloud moves by file ID end to end (spec #33 I2, acceptance rows 2 and 3):
// two real Linux sync engines, each with its own paired device, against a
// review gateway and Nextcloud. Device B renames and moves items; device A
// (The VM host client) then applies them as local renames. Run by
// deploy/identity_cloud_move_fixture.py, which reads the gateway's request
// log for device A between the markers this tool prints.
//
//   dart run tool/identity_cloud_move_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, a: {certificate, key}, b: {certificate, key}, work,
// folder}. Prints one JSON result line (claims, each device's request log,
// local identities before and after, the UTC window of A's pass); exits
// non-zero on the first failed claim.
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

/// The Linux binding, counting the guarded renames the engine makes.
class _Counted extends NativeRootFs {
  final renames = <String>[];

  @override
  void renameExclusive(int fd, String from, String to, String identity) {
    super.renameExclusive(fd, from, to, identity);
    renames.add('$from -> $to');
  }
}

class _Device {
  _Device(Map<String, dynamic> config, Map<String, dynamic> own, String name) {
    final work = Directory('${config['work']}/$name')
      ..createSync(recursive: true);
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(config['ca'] as String)
      ..useCertificateChain(own['certificate'] as String)
      ..usePrivateKey(own['key'] as String);
    // As the worker builds it (folder deletion qualified), so the old
    // behaviour (a delete plus a download) would be sent and logged.
    dav = DavCloud(
      Uri.parse(config['origin'] as String),
      context,
      folderDeletionQualified: true,
    );
    cloud = _Logged(dav);
    tree = RootTree.setup(
      (Directory('${work.path}/files')..createSync()).path,
      'identity-$name',
      fs,
    );
    store = Manifest(Directory('${work.path}/profile'))
      ..setSetting('retention', 'local');
    engine = SyncEngine(store, tree, cloud);
  }

  late final DavCloud dav;
  late final _Logged cloud;
  final fs = _Counted();
  late final RootTree tree;
  late final Manifest store;
  late final SyncEngine engine;

  Future<void> settle([int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await engine.tick();
    }
  }
}

Future<void> main(List<String> args) async {
  final config =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(config['work'] as String);
  if (work.existsSync()) throw StateError('Fixture work path must be absent.');
  final a = _Device(config, config['a'] as Map<String, dynamic>, 'a');
  final b = _Device(config, config['b'] as Map<String, dynamic>, 'b');
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

  String at(_Device d, String name) => '${d.tree.root.path}/$folder/$name';
  void write(_Device d, String name, String text) => File(at(d, name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text, flush: true);
  bool exists(_Device d, String name) =>
      FileSystemEntity.typeSync(at(d, name), followLinks: false) !=
      FileSystemEntityType.notFound;
  // Device and inode: the local identity the engine records.
  String identity(_Device d, String name) =>
      (Process.runSync('stat', ['-c', '%d:%i', at(d, name)]).stdout as String)
          .trim();
  Entry? row(_Device d, String name) => d.store.entries['$folder/$name'];
  List<String> requests(_Device d) => [
    for (final line in d.cloud.log)
      if (!line.startsWith('PROPFIND')) line.replaceAll('$folder/', ''),
  ];

  try {
    await a.settle(1);
    claim('A: folder synced down', Directory(at(a, '')).existsSync());
    write(a, 'Photos/Trip/a.jpg', 'a');
    write(a, 'Photos/Trip/deep/b.jpg', 'b');
    write(a, 'Photos/Trip/deep/deeper/c.jpg', 'c');
    write(a, 'Docs/report.txt', 'report v1');
    write(a, 'Docs/both.txt', 'both');
    write(a, 'Docs/gone.txt', 'gone');
    await a.settle();
    write(a, 'Docs/report.txt', 'report v2');
    await a.settle();
    await b.settle();
    claim(
      'B: library synced down',
      File(at(b, 'Photos/Trip/deep/deeper/c.jpg')).existsSync() &&
          File(at(b, 'Docs/report.txt')).readAsStringSync() == 'report v2',
    );
    // A second pass on A, so its rows record the folder file IDs.
    await a.settle(2);
    final names = [
      'Docs/report.txt',
      'Photos/Trip',
      'Photos/Trip/deep/b.jpg',
      'Docs/both.txt',
    ];
    final before = {for (final n in names) n: identity(a, n)};
    result['identitiesBefore'] = before;
    result['fileIdsBefore'] = {
      for (final n in names) n: row(a, n)?.fileId,
    };

    // Row 2, alone: device B moves a file into a new folder and a folder
    // with a deep subtree; device A then applies both.
    Directory(at(b, 'Archive')).createSync();
    File(
      at(b, 'Docs/report.txt'),
    ).renameSync(at(b, 'Archive/Report 2026.txt'));
    Directory(at(b, 'Photos/Trip')).renameSync(at(b, 'Archive/Trip 2026'));
    b.cloud.log.clear();
    await b.settle();
    final sentB2 = requests(b);
    claim(
      'B (row 2): one MOVE per top item',
      sentB2.where((r) => r.startsWith('MOVE')).length == 2,
      sentB2,
    );
    a.cloud.log.clear();
    a.fs.renames.clear();
    result['row2Start'] = DateTime.now().toUtc().toIso8601String();
    await a.settle();
    result['row2End'] = DateTime.now().toUtc().toIso8601String();
    final sent2 = requests(a);
    final renames2 = [
      for (final r in a.fs.renames) r.replaceAll('$folder/', ''),
    ];
    result['row2'] = {
      'requestsB': sentB2,
      'requestsA': sent2,
      'listingsA': a.cloud.log.where((l) => l.startsWith('PROPFIND')).length,
      'renamesA': renames2,
    };
    claim('A (row 2): nothing sent but listings', sent2.isEmpty, sent2);
    claim(
      'A (row 2): one local rename per moved top item (one for the folder)',
      renames2.length == 2 &&
          renames2.contains('Photos/Trip -> Archive/Trip 2026') &&
          renames2.contains('Docs/report.txt -> Archive/Report 2026.txt'),
      renames2,
    );

    // Row 3, cloud rows: the same item renamed on A to another name, and an
    // item A deletes while B moves it. A is offline meanwhile.
    File(at(b, 'Docs/both.txt')).renameSync(at(b, 'Docs/both-there.txt'));
    File(at(b, 'Docs/gone.txt')).renameSync(at(b, 'Archive/gone.txt'));
    File(at(a, 'Docs/both.txt')).renameSync(at(a, 'Docs/both-here.txt'));
    File(at(a, 'Docs/gone.txt')).deleteSync();
    b.cloud.log.clear();
    await b.settle();
    final sentB3 = requests(b);
    claim(
      'B (row 3): one MOVE per item',
      sentB3.where((r) => r.startsWith('MOVE')).length == 2,
      sentB3,
    );
    a.cloud.log.clear();
    a.fs.renames.clear();
    result['row3Start'] = DateTime.now().toUtc().toIso8601String();
    await a.settle();
    result['row3End'] = DateTime.now().toUtc().toIso8601String();
    final sent3 = requests(a);
    final renames3 = [
      for (final r in a.fs.renames) r.replaceAll('$folder/', ''),
    ];
    result['row3'] = {
      'requestsB': sentB3,
      'requestsA': sent3,
      'listingsA': a.cloud.log.where((l) => l.startsWith('PROPFIND')).length,
      'renamesA': renames3,
    };
    claim(
      'A (row 3): the cloud name wins (no MOVE, PUT or GET); the delete '
      'follows the item (one DELETE at its new path)',
      sent3.length == 1 && sent3.single == 'DELETE Archive/gone.txt',
      sent3,
    );
    claim(
      'A (row 3): one local rename, to the cloud name',
      renames3.length == 1 &&
          renames3.single == 'Docs/both-here.txt -> Docs/both-there.txt',
      renames3,
    );
    final after = {
      'Docs/report.txt': identity(a, 'Archive/Report 2026.txt'),
      'Photos/Trip': identity(a, 'Archive/Trip 2026'),
      'Photos/Trip/deep/b.jpg': identity(a, 'Archive/Trip 2026/deep/b.jpg'),
      'Docs/both.txt': identity(a, 'Docs/both-there.txt'),
    };
    result['identitiesAfter'] = after;
    claim(
      'A: every local identity (device:inode) unchanged at its new path',
      names.every((n) => before[n] == after[n]),
    );
    claim(
      'A: old and local-only names gone, contents unchanged',
      !exists(a, 'Docs/report.txt') &&
          !exists(a, 'Photos/Trip') &&
          !exists(a, 'Docs/both-here.txt') &&
          !exists(a, 'Archive/gone.txt') &&
          File(at(a, 'Archive/Report 2026.txt')).readAsStringSync() ==
              'report v2' &&
          File(
                at(a, 'Archive/Trip 2026/deep/deeper/c.jpg'),
              ).readAsStringSync() ==
              'c',
    );
    claim(
      'A: rows current at the new paths, the cloud name noted once',
      row(a, 'Archive/Report 2026.txt')?.status == 'current local' &&
          row(a, 'Archive/Trip 2026/deep/deeper/c.jpg')?.status ==
              'current local' &&
          row(a, 'Docs/both-there.txt')?.movedNote ==
              'Renamed on another device to both-there.txt' &&
          row(a, 'Archive/Report 2026.txt')?.movedNote == null &&
          row(a, 'Docs/both-here.txt') == null,
    );
    claim(
      'A: file IDs kept on the moved rows',
      row(a, 'Archive/Report 2026.txt')?.fileId ==
              (result['fileIdsBefore'] as Map)['Docs/report.txt'] &&
          row(a, 'Archive/Trip 2026')?.fileId ==
              (result['fileIdsBefore'] as Map)['Photos/Trip'],
    );
    final listed = {
      for (final item in await a.dav.snapshot())
        if (item.path.startsWith('$folder/'))
          item.path.substring(folder.length + 1),
    };
    claim(
      'cloud: the deleted item is gone, nothing created at the local names',
      !listed.contains('Archive/gone.txt') &&
          !listed.contains('Docs/both-here.txt') &&
          listed.contains('Docs/both-there.txt'),
      listed.toList()..sort(),
    );
    stdout.writeln(jsonEncode(result));
  } finally {
    a.engine.close();
    b.engine.close();
  }
}
