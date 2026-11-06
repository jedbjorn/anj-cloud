// Portable names end to end (decision #120): a real Linux sync engine against
// a review gateway. Run by deploy/name_fixture.py, which pairs the device and
// checks the gateway directly; this side proves the client row and Rename.
// (Plain Dart: the row's badge and visibility are covered by widget tests.)
//
//   dart run tool/name_policy_fixture.dart CONFIG.json
//
// CONFIG: {origin, ca, certificate, key, work, folder}. Prints one JSON
// result line; exits non-zero on the first failed claim.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/entry_projection.dart';
import 'package:anj_cloud/core/sync/name_policy.dart';
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
  final cloud = DavCloud(Uri.parse(config['origin'] as String), context);
  final tree = RootTree.setup(
    (Directory('${work.path}/files')..createSync()).path,
    'names-e2e',
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

  File local(String name) => File('${tree.root.path}/$folder/$name');
  Future<Set<String>> server() async => {
    for (final item in await cloud.snapshot())
      if (item.path.startsWith('$folder/'))
        item.path.substring(folder.length + 1),
  };
  Future<Map<String, dynamic>> row(String name) async =>
      Map.of(await projectEntry(engine, store.entries['$folder/$name']!));

  try {
    await engine.tick();
    claim(
      'folder synced down',
      Directory('${tree.root.path}/$folder').existsSync(),
    );
    for (final name in [
      'CON.txt',
      'report.txt',
      '.bashrc',
      'Notes.txt',
      'late.txt',
    ]) {
      local(name).writeAsStringSync('local $name', flush: true);
    }
    var injected = false;
    await engine.tick(
      between: () async {
        // Another device creates LATE.txt after this pass listed the cloud:
        // only the gateway can refuse late.txt now.
        if (!injected) {
          injected = true;
          final source = File('${work.path}/late-source')
            ..writeAsStringSync('other device');
          await cloud.upload('$folder/LATE.txt', source, etag: null);
        }
        return false;
      },
    );
    await engine.tick();
    final names = await server();
    claim(
      'ordinary name and dotfile uploaded',
      names.containsAll(['report.txt', '.bashrc']),
      names.toList(),
    );
    claim('blocked name not uploaded', !names.contains('CON.txt'));
    claim(
      'client clash not uploaded',
      !names.contains('Notes.txt') && names.contains('notes.txt'),
    );
    claim(
      'gateway refusal kept local',
      !names.contains('late.txt') && names.contains('LATE.txt'),
    );
    for (final name in ['CON.txt', 'Notes.txt', 'late.txt']) {
      final projected = await row(name);
      claim(
        'row for $name',
        projected['status'] == nameNotAllowedStatus &&
            projected['nameRefused'] == true &&
            (projected['presentationErrors'] as List).contains(
              nameNotAllowedStatus,
            ) &&
            local(name).readAsStringSync() == 'local $name',
        projected['status'],
      );
    }
    claim(
      'Linux holds the server notes.txt too',
      local('notes.txt').existsSync(),
    );
    final renamed = await engine.renameLocal('$folder/CON.txt', 'console.txt');
    claim(
      'rename in place',
      renamed == '$folder/console.txt' && !local('CON.txt').existsSync(),
    );
    await engine.tick();
    await engine.tick();
    final after = await server();
    claim(
      'renamed file synced',
      after.contains('console.txt') && !after.contains('CON.txt'),
      after.toList(),
    );
    final download = File('${work.path}/check');
    final version = (await cloud.snapshot()).firstWhere(
      (item) => item.path == '$folder/console.txt',
    );
    await cloud.download('$folder/console.txt', download, etag: version.etag);
    claim(
      'renamed bytes intact',
      download.readAsStringSync() == 'local CON.txt',
    );
    claim(
      'old row hidden',
      (await row('CON.txt'))['status'] == 'removed locally',
    );
    stdout.writeln(jsonEncode({'passed': true, 'claims': claims}));
  } finally {
    engine.close();
    cloud.close();
  }
}
