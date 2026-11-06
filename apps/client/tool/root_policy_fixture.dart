// Process interruption fixture for the legacy root-policy transaction.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fixture_cloud.dart';

class _CrashManifest extends Manifest {
  _CrashManifest(super.profile, this.phase);
  final String phase;
  @override
  void save({Map<String, String> settings = const {}}) {
    super.save(settings: settings);
    if (phase == 'after-commit' && settings['retention'] == 'local') exit(86);
  }
}

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final marker = File('${fixture.path}/.anj-root-policy-fixture');
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
          'root-policy-crash',
          native,
        )
      : RootTree(
          Directory(store.setting('root')!),
          Directory(store.setting('staging')!),
          native,
        );
  final cloud = FixtureCloud(Directory('${fixture.path}/cloud'));
  final engine = SyncEngine(store, tree, cloud);
  if (fresh) {
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
    store.setSetting('retention', 'cloud');
    Directory('${cloud.root.path}/Old').createSync();
    cloud
        .file('Old/remote.txt')
        .writeAsStringSync('remote retained', flush: true);
    File('${tree.root.path}/local.txt')
        .writeAsStringSync('local retained', flush: true);
    store.db.execute(
      "CREATE TRIGGER crash_migration AFTER INSERT ON entries WHEN NEW.path='Old' BEGIN SELECT interrupt_migration(); END",
    );
  }
  if (args[1] == 'before-commit') {
    store.db.createFunction(
      functionName: 'interrupt_migration',
      directOnly: false,
      argumentCount: const AllowedArgumentCount(0),
      function: (_) => exit(86),
    );
  } else {
    store.db.execute('DROP TRIGGER IF EXISTS crash_migration');
  }
  await engine.tick();
  if (store.setting('retention') != 'local' ||
      engine.retention('Old/remote.txt').name != 'cloud' ||
      File('${tree.root.path}/Old/remote.txt').existsSync() ||
      cloud.file('Old/remote.txt').readAsStringSync() != 'remote retained' ||
      cloud.file('local.txt').readAsStringSync() != 'local retained') {
    throw StateError(
      'Migration did not preserve Cloud intent and complete bytes',
    );
  }
  File('${tree.root.path}/new.txt')
      .writeAsStringSync('new Local file', flush: true);
  await engine.tick();
  if (engine.retention('new.txt').name != 'local' ||
      File('${tree.root.path}/new.txt').readAsStringSync() !=
          'new Local file') {
    throw StateError('New top-level file did not inherit fixed Local default');
  }
  engine.close();
}
