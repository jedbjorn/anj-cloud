// Real-process crash fixture for Recover and Dismiss (spec #25). Synthetic
// data in a disposable directory only; never a live profile or root.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

const target = 'Documents/probe.bin';
const bytes = 'only copy of these bytes';

/// Refuses every upload, so the file is removed before it ever synced and
/// its snapshot becomes a recovery copy (the SC-028 / Laptop state).
class _RefusingCloud extends FixtureCloud {
  _RefusingCloud(super.root);
  @override
  Future<String> upload(String path, File source, {required String? etag}) =>
      throw const CloudFailure('Write failed');
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Supply an absent disposable fixture path and a crash phase or resume.',
    );
  }
  final fixture = Directory(arguments[0]);
  final marker = File('${fixture.path}/.anj-recover-dismiss-fixture');
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
    tree = RootTree.setup(parent.path, 'recover-dismiss-fixture', native);
    manifest.setSetting('profileId', 'recover-dismiss-fixture');
    manifest.setSetting('root', tree.root.path);
    manifest.setSetting('staging', tree.staging.path);
    manifest.setSetting('retention', 'local');
    tree.ensureDirectory('Documents');
    File('${tree.root.path}/$target').writeAsStringSync(bytes, flush: true);
  } else {
    tree = RootTree(
      Directory(manifest.setting('root')!),
      Directory(manifest.setting('staging')!),
      native,
    );
  }
  final cloudRoot = Directory('${fixture.path}/cloud');
  final phase = arguments[1];
  if (fresh) {
    final engine = SyncEngine(manifest, tree, _RefusingCloud(cloudRoot));
    await engine.tick();
    File('${tree.root.path}/$target').deleteSync();
    await engine.tick();
    if (engine.recovery.describe(target) == null) {
      throw StateError('The fixture did not produce a recovery copy.');
    }
    engine.recovery.barrier = (point, record) {
      if (point == phase) {
        File('${fixture.path}/crash.json').writeAsStringSync(
          jsonEncode({'phase': point, 'record': record.toJson()}),
          flush: true,
        );
        exit(86);
      }
    };
    final copies = engine.recovery.describe(target)!['paths'] as List;
    engine.applyBulk(phase.startsWith('recover') ? 'recover' : 'dismiss', [
      {'path': target, 'kind': 'file', 'copies': copies},
    ]);
    throw StateError('The action finished without reaching $phase.');
  }
  final cloud = FixtureCloud(cloudRoot);
  final engine = SyncEngine(manifest, tree, cloud);
  await engine.tick();
  final names = tree.staging
      .listSync()
      .map((f) => f.uri.pathSegments.last)
      .toList();
  final recorded = {
    for (final record in engine.artifacts.records)
      record.data['name'] as String,
  };
  final root = File('${tree.root.path}/$target');
  final result = {
    'status': manifest.entries[target]?.status,
    'root': root.existsSync() ? root.readAsStringSync() : null,
    'cloud': cloud.file(target).existsSync()
        ? cloud.file(target).readAsStringSync()
        : null,
    'staged': names,
    'unrecorded': names.where((name) => !recorded.contains(name)).toList(),
    'records': engine.artifacts.records
        .where((o) => (o.data['entryPath'] ?? o.path) == target)
        .map((o) => o.data['role'])
        .toList(),
    'retained': manifest.operations.values
        .where((o) => o.kind == 'retained')
        .map((o) => File(o.staged!).existsSync())
        .toList(),
    'intents': manifest.operations.values
        .where((o) => o.kind == 'recover' || o.data['dismissing'] == true)
        .length,
    'copies': engine.recovery.describe(target),
  };
  File('${fixture.path}/result.json')
      .writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
