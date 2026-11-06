// Crash fixture for exclusion adoption. Only marked synthetic private paths.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/core/sync/sync_path_policy.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final marker = File('${fixture.path}/.anj-exclusion-fixture');
  final fresh = !fixture.existsSync();
  if (!fresh && !marker.existsSync()) throw StateError('Not a fixture');
  fixture.createSync(recursive: true);
  marker.writeAsStringSync('synthetic only');
  final native = NativeRootFs();
  native.privateDir(fixture.path);
  final store = Manifest(Directory('${fixture.path}/profile'));
  late RootTree tree;
  if (fresh) {
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'exclusion-crash', native);
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
  } else {
    tree = RootTree(
      Directory(store.setting('root')!),
      Directory(store.setting('staging')!),
      native,
    );
  }
  final cloud = FixtureCloud(Directory('${fixture.path}/cloud'));
  final engine = SyncEngine(store, tree, cloud);
  const path = 'Documents/.old.kate.swp';
  if (fresh) {
    File('${tree.root.path}/$path')
        .writeAsStringSync('local editor data', flush: true);
    final remote = cloud.file(path);
    remote.parent.createSync(recursive: true);
    remote.writeAsStringSync('remote data', flush: true);
    store.entries[path] = Entry(path, ItemKind.file)
      ..expectedPresent = true
      ..etag = '"old"'
      ..baselineHash = 'old';
    final staged = engine.artifacts.reserve(path, 'upload')
      ..writeAsStringSync('private uncertain snapshot', flush: true);
    final hash = sha256.convert(staged.readAsBytesSync()).toString();
    engine.artifacts.complete(staged, hash: hash);
    store.operations['legacy-upload'] = Operation(
      'legacy-upload',
      'upload',
      path,
      hash: hash,
      expectedEtag: '"old"',
      staged: staged.path,
    );
    store.save();
  }
  engine.exclusions.barrier = (phase) {
    if (phase == args[1]) exit(86);
  };
  await engine.tick();
  final archive = store.operations['legacy-upload']!;
  final result = {
    'active_ignored': store.entries.keys.where(isSyncExcluded).length,
    'operation_kind': archive.kind,
    'original_phase': (archive.data['original'] as Map)['phase'],
    'local': File('${tree.root.path}/$path').readAsStringSync(),
    'remote': cloud.file(path).readAsStringSync(),
    'private': File(archive.staged!).readAsStringSync(),
  };
  File('${fixture.path}/result.json')
      .writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
