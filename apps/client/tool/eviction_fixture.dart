import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:anj_cloud/platform/native/eviction_native.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

int ownedAllocated(RootTree tree) {
  final native = EvictionNative(tree.native);
  final inodes = <String, int>{};
  for (final fd in [tree.fd, tree.stageFd]) {
    for (final entry in tree.native.scan(fd)) {
      if (entry['kind'] == 'file') {
        final info = native.info(fd, entry['path'] as String);
        inodes[info.identity] = info.allocated;
      }
    }
  }
  return inodes.values.fold(0, (a, b) => a + b);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Supply an absent disposable fixture path and a crash phase or resume.',
    );
  }
  final fixture = Directory(arguments[0]);
  final marker = File('${fixture.path}/.anj-eviction-fixture');
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
    tree = RootTree.setup(parent.path, 'crash-fixture', native);
    // An ordinary folder: Documents, Music and Videos are never Cloud-only
    // (spec #34 P7).
    tree.ensureDirectory('Library');
    manifest.setSetting('profileId', 'crash-fixture');
    manifest.setSetting('root', tree.root.path);
    manifest.setSetting('staging', tree.staging.path);
    final random = Random(731);
    File('${tree.root.path}/Library/blob.bin').writeAsBytesSync(
      List.generate(4 * 1024 * 1024, (_) => random.nextInt(256)),
      flush: true,
    );
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
    engine.setRetention('Library', Retention.cloud);
  }
  final before = ownedAllocated(tree);
  engine.evictions.barrier = (phase, op, fd) {
    if (phase == arguments[1]) {
      File('${fixture.path}/crash.json').writeAsStringSync(
        jsonEncode({
          'phase': phase,
          'op': op.toJson(),
          'owned_allocated_before': before,
        }),
        flush: true,
      );
      exit(86);
    }
  };
  await engine.tick();
  final remote = cloud.file('Library/blob.bin');
  final result = {
    'root_present': File('${tree.root.path}/Library/blob.bin').existsSync(),
    'status': manifest.entries['Library/blob.bin']?.status,
    'pending_evictions': manifest.operations.values
        .where((o) => o.kind == 'evict')
        .length,
    'owned_allocated_before': before,
    'owned_allocated_after': ownedAllocated(tree),
    'remote_hash': (await sha256.bind(remote.openRead()).first).toString(),
  };
  File('${fixture.path}/result.json')
      .writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
