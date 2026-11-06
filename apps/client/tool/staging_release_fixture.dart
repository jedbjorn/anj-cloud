// Real-process crash fixture for staging release ordering (spec #12, rule 4).
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

const target = 'Documents/note.txt';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Supply an absent disposable fixture path and a crash phase or resume.',
    );
  }
  final fixture = Directory(arguments[0]);
  final marker = File('${fixture.path}/.anj-staging-release-fixture');
  if (fixture.existsSync() && !marker.existsSync()) {
    throw StateError('Refusing an existing non-fixture directory.');
  }
  final fresh = !fixture.existsSync();
  fixture.createSync(recursive: true);
  marker.writeAsStringSync('synthetic only');
  final native = NativeRootFs();
  native.privateDir(fixture.path);
  final profile = Directory('${fixture.path}/profile')..createSync();
  native.privateDir(profile.path);
  final manifest = Manifest(profile);
  late RootTree tree;
  if (fresh) {
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'release-crash-fixture', native);
    manifest.setSetting('profileId', 'release-crash-fixture');
    manifest.setSetting('root', tree.root.path);
    manifest.setSetting('staging', tree.staging.path);
    File(
      '${tree.root.path}/$target',
    ).writeAsStringSync('deleted everywhere', flush: true);
  } else {
    tree = RootTree(
      Directory(manifest.setting('root')!),
      Directory(manifest.setting('staging')!),
      native,
    );
  }
  final cloud = FixtureCloud(Directory('${fixture.path}/cloud'));
  final engine = SyncEngine(manifest, tree, cloud);
  if (fresh) {
    await engine.tick();
    engine.requestDelete(target);
    engine.releases.barrier = (phase, record, fd) {
      if (phase == arguments[1] && record.data['role'] == 'preserved') {
        File('${fixture.path}/crash.json').writeAsStringSync(
          jsonEncode({'phase': phase, 'record': record.toJson()}),
          flush: true,
        );
        exit(86);
      }
    };
  }
  await engine.tick();
  final names = tree.staging
      .listSync()
      .map((f) => f.uri.pathSegments.last)
      .toList();
  final recorded = {
    for (final record in engine.artifacts.records)
      record.data['name'] as String,
  };
  final result = {
    'status': manifest.entries[target]?.status,
    'remote_present': cloud.file(target).existsSync(),
    'root_present': File('${tree.root.path}/$target').existsSync(),
    'staged': names,
    'unrecorded': names.where((name) => !recorded.contains(name)).toList(),
    'records': engine.artifacts.records
        .where((o) => (o.data['entryPath'] ?? o.path) == target)
        .map((o) => o.data['role'])
        .toList(),
    'retained': manifest.operations.values
        .where((o) => o.kind == 'retained')
        .length,
    'preserved_copies': manifest.entries[target]?.preservedCopies,
    'message': engine.message,
  };
  File(
    '${fixture.path}/result.json',
  ).writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
