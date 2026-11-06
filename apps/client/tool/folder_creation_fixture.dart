// Process interruption at the durable folder publication boundaries.
import 'dart:io';

import 'package:anj_cloud/core/gateway/cloud_api.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

class _CrashManifest extends Manifest {
  _CrashManifest(super.profile, this.phase);
  final String phase;
  @override
  void save({Map<String, String> settings = const {}}) {
    final completed = entries.containsKey('Created');
    if (phase == 'after-publish' && completed) exit(86);
    super.save(settings: settings);
    if ((phase == 'after-intent' &&
            operations.values.any((op) => op.kind == 'createFolder')) ||
        (phase == 'after-commit' && completed)) {
      exit(86);
    }
  }
}

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final marker = File('${fixture.path}/.anj-folder-fixture');
  final fresh = !fixture.existsSync();
  if (!fresh && !marker.existsSync()) throw StateError('Not a fixture');
  fixture.createSync(recursive: true);
  marker.writeAsStringSync('synthetic only');
  final native = NativeRootFs();
  native.privateDir(fixture.path);
  final store = _CrashManifest(Directory('${fixture.path}/profile'), args[1]);
  final tree = fresh
      ? RootTree.setup(
          (Directory('${fixture.path}/files')..createSync()).path,
          'folder-crash',
          native,
        )
      : RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          native,
        );
  if (fresh) {
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
  }
  final engine = SyncEngine(store, tree, const DisconnectedCloud());
  if (fresh) await engine.createFolder('', 'Created', Retention.cloud);
  await engine.tick();
  if (args[1] == 'resume-pending') {
    if (store.entries.containsKey('Created') ||
        !Directory('${tree.root.path}/Created').existsSync() ||
        store.operations.values
                .where((op) => op.kind == 'createFolder')
                .length !=
            1 ||
        !engine.message.contains('needs review after interruption')) {
      throw StateError('Ambiguous publication was not preserved as pending');
    }
    engine.close();
    return;
  }
  if (store.entries['Created']?.override != Retention.cloud ||
      !Directory('${tree.root.path}/Created').existsSync() ||
      store.operations.values.any((op) => op.kind == 'createFolder')) {
    throw StateError('Folder publication/policy did not recover together');
  }
  final saved = File('${tree.root.path}/Created/saved.txt')
    ..writeAsStringSync('offline saved bytes', flush: true);
  await engine.tick();
  if (saved.readAsStringSync() != 'offline saved bytes' ||
      engine.retention('Created/saved.txt') != Retention.cloud) {
    throw StateError('Offline file lost bytes or directory policy');
  }
  engine.close();
}
