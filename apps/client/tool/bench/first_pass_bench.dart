// First-pass cost (flag SC-057, spec #33 I4 row 10): a real SyncEngine,
// RootTree and Manifest on disk under --work, against an in-memory listing of
// --files new Cloud-only files (100 per folder). Prints one JSON line. Run it
// with and without --enable-asserts: test and debug builds verify manifest
// tracking on every commit, release builds do not.
//
//   dart [--enable-asserts] run tool/bench/first_pass_bench.dart \
//       --files 10000 --work DIR
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import '../../test/fakes.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    options[args[i].replaceFirst('--', '')] = args[i + 1];
  }
  final files = int.parse(options['files'] ?? '10000');
  final work = Directory(options['work'] ?? (throw ArgumentError('--work')));
  if (work.existsSync()) throw StateError('--work must not exist yet.');
  work.createSync(recursive: true);
  try {
    final parent = Directory('${work.path}/files')..createSync();
    final tree = RootTree.setup(parent.path, 'first-pass', NativeRootFs());
    final store = Manifest(Directory('${work.path}/profile'));
    final cloud = FakeCloud();
    final engine = SyncEngine(store, tree, cloud);
    tree.ensureDirectory('Photos');
    await engine.tick();
    engine.setRetention('Photos', Retention.cloud);
    await engine.tick();
    for (var d = 0; d < files ~/ 100; d++) {
      await cloud.mkdir('Photos/d$d');
      for (var f = 0; f < 100; f++) {
        cloud.put('Photos/d$d/f$f.jpg', 'x', modifiedAt: 1700000000 + f);
      }
    }
    final result = <String, Object?>{'files': files};
    var asserts = false;
    assert(asserts = true);
    result['asserts'] = asserts;
    for (final pass in ['first', 'second']) {
      final transactions = store.transactions;
      final watch = Stopwatch()..start();
      await engine.tick();
      result['${pass}_pass_ms'] = watch.elapsedMilliseconds;
      result['${pass}_pass_commits'] = store.transactions - transactions;
    }
    result['cloud_only_rows'] = store.entries.values
        .where((entry) => entry.status == 'cloud-only')
        .length;
    engine.close();
    stdout.writeln(jsonEncode(result));
  } finally {
    work.deleteSync(recursive: true);
  }
}
