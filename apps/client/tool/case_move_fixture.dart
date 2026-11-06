// Case- and normalization-only renames end to end (SC-054): a real Linux
// sync engine against a review gateway and Nextcloud. Run by
// deploy/case_move_fixture.py, which pairs the device and checks the
// gateway's MOVE directly; this side proves what the client does.
//
//   dart run tool/case_move_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, certificate, key, work, folder}. Prints one JSON
// result line; exits non-zero on the first failed claim.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

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
  // As the worker builds it (folder deletion qualified).
  final cloud = DavCloud(
    Uri.parse(config['origin'] as String),
    context,
    folderDeletionQualified: true,
  );
  final tree = RootTree.setup(
    (Directory('${work.path}/files')..createSync()).path,
    'case-e2e',
    NativeRootFs(),
  );
  final store = Manifest(Directory('${work.path}/profile'))
    ..setSetting('retention', 'local');
  final engine = SyncEngine(store, tree, cloud);
  final folder = config['folder'] as String;
  final claims = <String, Object?>{};
  void claim(String name, bool passed, [Object? detail]) {
    claims[name] = detail ?? passed;
    if (!passed) {
      stdout.writeln(jsonEncode({'failed': name, 'claims': claims}));
      exit(1);
    }
  }

  String at(String name) => '${tree.root.path}/$folder/$name';
  void write(String name, String text) => File(at(name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text, flush: true);
  // Server items under the folder: relative path -> (file ID, version).
  Future<Map<String, (int?, String)>> server() async => {
    for (final item in await cloud.snapshot())
      if (item.path.startsWith('$folder/'))
        item.path.substring(folder.length + 1): (item.fileId, item.etag),
  };
  int inode(String name) => int.parse(
    (Process.runSync('stat', ['-c', '%i', at(name)]).stdout as String).trim(),
  );
  Future<void> ticks() async {
    await engine.tick();
    await engine.tick();
  }

  String status(String name) => store.entries['$folder/$name']!.status;

  try {
    await engine.tick();
    claim('folder synced down', Directory(at('')).existsSync());
    write('Photos/2026/a.jpg', 'a');
    write('Photos/2026/b.jpg', 'b');
    write('Photos/top.txt', 'top');
    write('Report.txt', 'report');
    write('café.txt', 'nfc');
    await ticks();
    final before = await server();
    claim(
      'uploaded',
      before.keys.toSet().containsAll([
        'Photos/2026/a.jpg',
        'Photos/top.txt',
        'Report.txt',
        'café.txt',
      ]),
      before.keys.toList(),
    );

    // 1. Local case-only renames: one MOVE each, the server keeps the items.
    // The child is renamed together with its folder: both move.
    File(at('Photos/top.txt')).renameSync(at('Photos/TOP.txt'));
    Directory(at('Photos')).renameSync(at('photos'));
    File(at('Report.txt')).renameSync(at('report.txt'));
    await ticks();
    final moved = await server();
    claim(
      'local folder rename (and its child renamed with it) moved the '
      'subtree (same file IDs and versions)',
      !moved.keys.any((k) => k.startsWith('Photos')) &&
          moved['photos/2026/a.jpg'] == before['Photos/2026/a.jpg'] &&
          moved['photos/2026/b.jpg'] == before['Photos/2026/b.jpg'] &&
          moved['photos/TOP.txt'] == before['Photos/top.txt'] &&
          !moved.containsKey('photos/top.txt') &&
          moved['photos']?.$1 == before['Photos']?.$1,
      moved.keys.toList(),
    );
    claim(
      'local file rename moved the file',
      moved['report.txt'] == before['Report.txt'] &&
          !moved.containsKey('Report.txt'),
    );
    claim(
      'rows current under the new spelling',
      [
            'photos',
            'photos/2026/a.jpg',
            'report.txt',
          ].every((n) => status(n) == 'current local') &&
          !store.entries.keys.any((k) => k.startsWith('$folder/Photos')),
    );

    // 2. A cloud case-only rename (as another device makes it): the local
    // folder is renamed in place, nothing downloaded.
    final node = inode('photos/2026/a.jpg');
    await cloud.move(
      '$folder/photos',
      '$folder/PHOTOS',
      etag: (await cloud.snapshot())
          .firstWhere((i) => i.path == '$folder/photos')
          .etag,
    );
    await ticks();
    final names = Directory(at('')).listSync().map((e) => e.uri.pathSegments);
    claim(
      'cloud folder rename renamed the local folder in place',
      Directory(at('PHOTOS')).existsSync() &&
          !Directory(at('photos')).existsSync() &&
          inode('PHOTOS/2026/a.jpg') == node &&
          File(at('PHOTOS/2026/a.jpg')).readAsStringSync() == 'a',
      names.map((s) => s.where((v) => v.isNotEmpty).last).toList(),
    );
    claim(
      'rows current, no recovery copy',
      status('PHOTOS/2026/a.jpg') == 'current local' &&
          store.entries.values.every((e) => e.preservedCopies.isEmpty) &&
          !store.entries.keys.any((k) => k.startsWith('$folder/photos')),
    );

    // 3. Normalization only (decision #138): the cloud spelling is NFC, so
    // a rename to the NFD spelling is one name in the cloud. Nothing is
    // sent; the row takes the local spelling.
    File(at('café.txt')).renameSync(at('café.txt'));
    await ticks();
    final nfd = await server();
    claim(
      'NFC->NFD rename: the cloud item is unchanged (same file ID, version)',
      nfd['café.txt'] == before['café.txt'] && !nfd.containsKey('café.txt'),
      nfd.keys.map((k) => k.runes.toList()).toList(),
    );
    claim(
      'NFC->NFD rename: row current under the NFD spelling, kept on disk',
      status('café.txt') == 'current local' &&
          !store.entries.containsKey('$folder/café.txt') &&
          File(at('café.txt')).readAsStringSync() == 'nfc' &&
          !File(at('café.txt')).existsSync(),
    );

    // 4. A brand-new NFD file and folder (as macOS-origin names arrive on
    // Linux): uploaded in NFC, the same items on every later pass.
    write('Résumé/café menu.txt', 'menu');
    await ticks();
    final fresh = await server();
    claim(
      'new NFD names stored in NFC',
      fresh.containsKey('Résumé') &&
          fresh.containsKey('Résumé/café menu.txt') &&
          !fresh.keys.any((k) => k.contains('́')),
      fresh.keys.map((k) => k.runes.toList()).toList(),
    );
    await ticks();
    await ticks();
    final settled = await server();
    claim(
      'new NFD names settle: no upload, move or delete across passes',
      settled['Résumé/café menu.txt'] == fresh['Résumé/café menu.txt'] &&
          settled['café.txt'] == before['café.txt'] &&
          settled.length == fresh.length,
    );
    claim(
      'new NFD names keep their spelling here, no NFC duplicate',
      Directory(at('Résumé')).existsSync() &&
          !Directory(at('Résumé')).existsSync() &&
          status('Résumé/café menu.txt') == 'current local' &&
          !store.entries.keys.any(
            (k) => k.startsWith('$folder/') && k.contains('é'),
          ),
    );
    claim(
      'no item left in conflict or pending',
      store.entries.values
          .where((e) => e.path.startsWith('$folder/'))
          .every(
            (e) =>
                e.conflict == null &&
                !e.status.contains('pending') &&
                e.kind != ItemKind.unsupported,
          ),
    );
    stdout.writeln(jsonEncode({'passed': true, 'claims': claims}));
  } finally {
    engine.close();
    cloud.close();
  }
}
