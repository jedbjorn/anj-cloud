// Real-process crash fixture. Operates only within its private marked directory.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'eviction_fixture.dart' show ownedAllocated;
import 'fixture_cloud.dart';

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final marker = File('${fixture.path}/.anj-edit-completion-fixture');
  final fresh = !fixture.existsSync();
  if (!fresh && !marker.existsSync()) throw StateError('Not an owned fixture');
  fixture.createSync(recursive: true);
  marker.writeAsStringSync('synthetic only');
  final native = NativeRootFs();
  native.privateDir(fixture.path);
  final store = Manifest(Directory('${fixture.path}/profile'));
  late RootTree tree;
  final cloud = FixtureCloud(Directory('${fixture.path}/cloud'));
  const path = 'Library/edit.bin';
  if (fresh) {
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'completion-crash', native);
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
    store.setSetting('retention', 'cloud');
    final remote = cloud.file(path);
    remote.parent.createSync(recursive: true);
    remote.writeAsStringSync('synthetic editor result', flush: true);
  } else {
    tree = RootTree(
      Directory(store.setting('root')!),
      Directory(store.setting('staging')!),
      native,
    );
  }
  final engine = SyncEngine(store, tree, cloud);
  if (fresh) {
    await engine.tick();
    final opened = File(await engine.openFile(path));
    opened.writeAsStringSync('saved version one', flush: true);
    await engine.tick();
    opened.writeAsStringSync('saved version two', flush: true);
    await engine.tick();
    engine.editing.request(
      path,
      engine
          .workingCopies(path)
          .map((v) => Map<String, dynamic>.from(v))
          .toList(),
    );
  }
  final before = ownedAllocated(tree);
  var count = 0;
  engine.editing.barrier = (phase, request, fd) {
    if (phase == args[1]) {
      if (args[1] == 'after-unlink-before-db' && count++ != 0) return;
      File('${fixture.path}/crash.json').writeAsStringSync(
        jsonEncode({'phase': phase, 'request': request.toJson()}),
        flush: true,
      );
      exit(86);
    }
  };
  await engine.tick();
  final result = {
    'working': engine.workingCopies(path),
    'status': store.entries[path]!.status,
    'pending': engine.editing.requests.length,
    'allocated_before': before,
    'allocated': ownedAllocated(tree),
    'remote_sha256': sha256
        .convert(cloud.file(path).readAsBytesSync())
        .toString(),
    'remote': cloud.file(path).readAsStringSync(),
  };
  File('${fixture.path}/result.json')
      .writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
