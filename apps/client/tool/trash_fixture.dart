// Trash end to end (spec #44 AC1, AC2): a real Linux sync engine against a
// review gateway with the /trash/ routes. Run by deploy/trash_client_fixture.py,
// which pairs the device and cleans up; this side proves one-step delete,
// the server and device trash, and Undo. (Plain Dart: the snackbar and the
// Trash view are covered by widget tests.)
//
//   dart run tool/trash_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, certificate, key, work, folder}. Prints one JSON
// result line; exits non-zero on the first failed claim.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/certificate_renewal.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/sync_activity.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_schedule.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:crypto/crypto.dart';

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
  // Wrapped as the app's worker wraps it: renewable identity, pause gate,
  // transfer activity.
  final cloud = ActivityCloud(
    PausableCloud(
      RenewableCloud(
        DavCloud(
          Uri.parse(config['origin'] as String),
          context,
          folderDeletionQualified: true,
        ),
      ),
    ),
    SyncActivity(),
  );
  final tree = RootTree.setup(
    (Directory('${work.path}/files')..createSync()).path,
    'trash-e2e',
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

  String path(String name) => '$folder/$name';
  File local(String name) => File('${tree.root.path}/$folder/$name');
  String sha(List<int> bytes) => sha256.convert(bytes).toString();
  Future<String?> serverSha(String name) async {
    final item = (await cloud.snapshot())
        .where((i) => i.path == path(name))
        .firstOrNull;
    if (item == null) return null;
    final copy = File(
      '${work.path}/check-${DateTime.now().microsecondsSinceEpoch}',
    );
    await cloud.download(path(name), copy, etag: item.etag);
    return sha(copy.readAsBytesSync());
  }

  Future<Set<String>> trashPaths() async => {
    for (final item in (await cloud.listTrash())!.items) item.path,
  };
  bool noRecoveryRow(String name) =>
      engine.recovery.describe(path(name)) == null &&
      !store.operations.values.any(
        (o) => o.kind == 'retained' && o.path == path(name),
      );
  Map<String, Object?> delete(List<String> names) =>
      engine.applyBulk('delete', [
        for (final name in names)
          {
            'path': path(name),
            'kind': store.entries[path(name)]!.kind.name,
            'selectionVersion': engine.selectionVersion(
              store.entries[path(name)]!,
            ),
          },
      ]);
  Future<void> settle() async {
    await engine.tick();
    await engine.tick();
  }

  try {
    await engine.tick();
    claim(
      'folder synced down',
      Directory('${tree.root.path}/$folder').existsSync(),
    );

    // AC1: a file whose deleted-version hash is unknown (the case that used
    // to keep a Recovery row), and a folder.
    local('unknown.txt').writeAsStringSync('unknown version', flush: true);
    tree.ensureDirectory(path('Album'));
    local('Album/one.txt').writeAsStringSync('one', flush: true);
    local('Album/two.txt').writeAsStringSync('two', flush: true);
    await settle();
    claim('uploaded', await serverSha('Album/two.txt') == sha('two'.codeUnits));
    store.entries[path('unknown.txt')]!
      ..remoteHash = null
      ..remoteHashEtag = null;
    store.save();
    final deleted = delete(['unknown.txt', 'Album']);
    claim(
      'one step: both accepted, rows hidden before any pass',
      deleted['accepted'] == 2 &&
          deleteQueued(engine, path('unknown.txt')) &&
          deleteQueued(engine, path('Album/one.txt')),
    );
    await settle();
    final inTrash = await trashPaths();
    claim(
      'server trash lists the file and the folder',
      inTrash.contains(path('unknown.txt')) && inTrash.contains(path('Album')),
      inTrash.where((p) => p.startsWith(folder)).toList(),
    );
    claim(
      'gone here and on the server',
      !local('unknown.txt').existsSync() &&
          !Directory('${tree.root.path}/$folder/Album').existsSync() &&
          await serverSha('unknown.txt') == null,
    );
    claim(
      'no Recovery row; the unproven copy is in the device trash',
      noRecoveryRow('unknown.txt') &&
          noRecoveryRow('Album/one.txt') &&
          engine.deviceTrash.items().any((c) => c.path == path('unknown.txt')),
    );
    final listing = await engine.trashListing();
    final entry = (listing['entries'] as List).cast<Map>().firstWhere(
      (e) => e['path'] == path('unknown.txt'),
    );
    claim(
      'one Trash entry for the deletion, server item and device copy',
      entry['serverId'] != null && entry['deviceId'] != null,
    );

    // AC2: Undo of a delete not yet sent.
    local('pending.txt').writeAsStringSync('pending bytes', flush: true);
    await settle();
    final pendingSha = sha(local('pending.txt').readAsBytesSync());
    final pending = delete(['pending.txt']);
    final undoPending = await engine.undoDelete(
      [path('pending.txt')],
      pending['at'] as int,
      server: false,
    );
    await settle();
    claim(
      'Undo before sending: same path, same bytes, server unchanged',
      ((undoPending['results'] as List).single as Map)['result'] ==
              'restored' &&
          sha(local('pending.txt').readAsBytesSync()) == pendingSha &&
          await serverSha('pending.txt') == pendingSha &&
          !(await trashPaths()).contains(path('pending.txt')),
    );

    // AC2: Undo after the server acknowledged.
    local('acked.txt').writeAsStringSync('acknowledged bytes', flush: true);
    await settle();
    final ackedSha = sha(local('acked.txt').readAsBytesSync());
    final acked = delete(['acked.txt']);
    await engine.tick();
    claim(
      'deleted on the server before Undo',
      !local('acked.txt').existsSync() && await serverSha('acked.txt') == null,
    );
    final undoAcked = await engine.undoDelete([
      path('acked.txt'),
    ], acked['at'] as int);
    await settle();
    claim(
      'Undo after the server: same path, same bytes, server matches',
      ((undoAcked['results'] as List).single as Map)['result'] == 'restored' &&
          sha(local('acked.txt').readAsBytesSync()) == ackedSha &&
          await serverSha('acked.txt') == ackedSha &&
          !local('acked (restored).txt').existsSync(),
    );

    // Undo of the unproven file: from the server; the device copy goes.
    final undoUnknown = await engine.undoDelete([
      path('unknown.txt'),
      path('Album'),
    ], deleted['at'] as int);
    await settle();
    claim(
      'Undo of the file and folder: back with their bytes',
      (undoUnknown['results'] as List).every(
            (r) => (r as Map)['result'] == 'restored',
          ) &&
          local('unknown.txt').readAsStringSync() == 'unknown version' &&
          local('Album/two.txt').readAsStringSync() == 'two' &&
          await serverSha('Album/one.txt') == sha('one'.codeUnits),
    );
    claim(
      'the redundant device copy was released',
      !engine.deviceTrash.items().any((c) => c.path == path('unknown.txt')),
    );

    // A name taken meanwhile: (restored), nothing overwritten.
    local('taken.txt').writeAsStringSync('deleted bytes', flush: true);
    await settle();
    final taken = delete(['taken.txt']);
    await engine.tick();
    local('taken.txt').writeAsStringSync('new file here', flush: true);
    await settle();
    final undoTaken = await engine.undoDelete([
      path('taken.txt'),
    ], taken['at'] as int);
    await settle();
    final result = (undoTaken['results'] as List).single as Map;
    claim(
      'Undo into a taken name gives (restored)',
      result['result'] == 'renamed' &&
          result['to'] == path('taken (restored).txt') &&
          local('taken.txt').readAsStringSync() == 'new file here' &&
          local('taken (restored).txt').readAsStringSync() == 'deleted bytes',
      result,
    );
    // Edited, then deleted before any pass sent the edit: the server trashes
    // the older version, and Undo brings back the edited bytes.
    local('edited.txt').writeAsStringSync('version one', flush: true);
    await settle();
    local('edited.txt').writeAsStringSync('version two', flush: true);
    final edited = delete(['edited.txt']);
    await engine.tick();
    final undoEdited = await engine.undoDelete([
      path('edited.txt'),
    ], edited['at'] as int);
    await settle();
    claim(
      'Undo of a file edited here brings back the edit, not the older server version',
      ((undoEdited['results'] as List).single as Map)['result'] == 'restored' &&
          local('edited.txt').readAsStringSync() == 'version two' &&
          await serverSha('edited.txt') == sha('version two'.codeUnits),
    );
    stdout.writeln(jsonEncode({'passed': true, 'claims': claims}));
  } finally {
    engine.close();
    cloud.close();
  }
}
