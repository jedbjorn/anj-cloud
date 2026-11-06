// Synthetic crash fixture: SIGKILL after an operation's intent is durable but
// before its network dispatch, then restart and converge. Never a gateway.
import 'dart:convert';
import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

/// Appends every dispatched mutation to a log that survives the kill.
class LoggingCloud extends FixtureCloud {
  LoggingCloud(super.root, this.log);
  final File log;
  @override
  Future<String> upload(String path, File source, {required String? etag}) {
    log.writeAsStringSync('upload $path\n', mode: FileMode.append, flush: true);
    return super.upload(path, source, etag: etag);
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) {
    log.writeAsStringSync('delete $path\n', mode: FileMode.append, flush: true);
    return super.deleteFile(path, etag: etag);
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    throw ArgumentError(
      'Supply an absent disposable fixture path and a phase or resume.',
    );
  }
  final fixture = Directory(arguments[0]);
  final marker = File('${fixture.path}/.anj-dispatch-fixture');
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
    tree = RootTree.setup(parent.path, 'dispatch-fixture', native);
    manifest.setSetting('profileId', 'dispatch-fixture');
    manifest.setSetting('root', tree.root.path);
    manifest.setSetting('staging', tree.staging.path);
    manifest.setSetting('retention', 'local');
  } else {
    tree = RootTree(
      Directory(manifest.setting('root')!),
      Directory(manifest.setting('staging')!),
      native,
    );
  }
  final cloud = LoggingCloud(
    Directory('${fixture.path}/cloud'),
    File('${fixture.path}/dispatch.log'),
  );
  // Not about the settle time of held deletions (spec #34 P7, H1).
  final engine = SyncEngine(manifest, tree, cloud)
    ..debugTopDeleteSettle = Duration.zero;
  final document = File('${tree.root.path}/Documents/report.txt');
  if (fresh) {
    document.writeAsStringSync('first synchronized bytes', flush: true);
    await engine.tick();
    if (arguments[1] == 'upload-before-dispatch') {
      document.writeAsStringSync('edited before crash', flush: true);
    } else {
      document.deleteSync();
    }
    engine.barrier = (phase, op) {
      if (phase != arguments[1]) return;
      File('${fixture.path}/crash.json').writeAsStringSync(
        jsonEncode({'phase': phase, 'op': op.toJson()}),
        flush: true,
      );
      // No orderly shutdown: the database sees exactly what was committed.
      Process.killPid(pid, ProcessSignal.sigkill);
      sleep(const Duration(seconds: 30));
    };
    await engine.tick();
    stderr.writeln('barrier ${arguments[1]} was not reached');
    exit(2);
  }
  for (var i = 0; i < 3; i++) {
    await engine.tick();
  }
  final entry = manifest.entries['Documents/report.txt'];
  final remote = cloud.file('Documents/report.txt');
  final result = {
    'status': entry?.status,
    'conflict': entry?.conflict,
    'pending': manifest.operations.values
        .where((o) => ['upload', 'delete', 'preserve'].contains(o.kind))
        .map((o) => o.kind)
        .toList(),
    'remote': remote.existsSync() ? remote.readAsStringSync() : null,
    'local': document.existsSync() ? document.readAsStringSync() : null,
  };
  File('${fixture.path}/result.json')
      .writeAsStringSync(jsonEncode(result), flush: true);
  stdout.writeln(jsonEncode(result));
  engine.close();
}
