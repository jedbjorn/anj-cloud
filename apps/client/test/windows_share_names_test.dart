import 'dart:io';

import 'package:anj_cloud/core/gateway/sharing.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/sync/cloud_names.dart';
import 'package:anj_cloud/core/sync/name_rule.dart';
import 'package:anj_cloud/core/sync/sync_engine.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sharing_engine_test.dart' show SharingCloud;

class _MkdirCloud extends SharingCloud {
  final List<String> made = [];
  @override
  Future<void> mkdir(String path) async {
    made.add(path);
    await super.mkdir(path);
  }
}

/// A placed incoming share under a Windows local name keeps its mount rules
/// across a restart (spec #49 Sync Boundary per-segment translation): the
/// incoming list, read before the first listing, comes back under the local
/// spelling its rows are keyed by.
void main() {
  late Directory fixture;
  late _MkdirCloud cloud;
  SyncEngine? engine;

  String rootPath() => '${fixture.path}/files/anj-cloud';

  SyncEngine open() {
    final names = CloudNames();
    return engine = SyncEngine(
      Manifest(Directory('${fixture.path}/profile')),
      RootTree(
        Directory(rootPath()),
        Directory('${fixture.path}/files/.stage'),
        NativeRootFs(),
      ),
      NamedCloud(cloud, names),
      names: names,
    )..nameOs = NameOs.windows;
  }

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-share-names-');
    Directory(rootPath()).createSync(recursive: true);
    Directory('${fixture.path}/files/.stage').createSync(recursive: true);
    cloud = _MkdirCloud();
  });
  tearDown(() {
    try {
      engine?.close();
    } on Object {
      // closed already
    }
    fixture.deleteSync(recursive: true);
  });

  test('an aliased placed share renamed while offline is renamed for '
      'everyone after a fresh-engine restart', () async {
    for (final folder in ['Documents', 'Documents/Trip?']) {
      cloud.directories.add(folder);
      cloud.versions[folder] = '"d-$folder"';
    }
    cloud.put('Documents/Trip?/a.txt', 'owner bytes');
    cloud.setShare('Documents/Trip?', SharePermission.edit);
    cloud.incoming = [
      const IncomingShare(
        '7',
        'Documents/Trip?',
        'Alice',
        SharePermission.edit,
      ),
    ];
    await open().tick();
    await engine!.tick();
    expect(
      File('${rootPath()}/Documents/Trip？/a.txt').readAsStringSync(),
      'owner bytes',
    );
    expect(engine!.isIncomingMountPath('Documents/Trip？'), isTrue);
    engine!.close();

    Directory('${rootPath()}/Documents/Trip？')
        .renameSync('${rootPath()}/Documents/Renamed');
    cloud.made.clear();
    await open().tick();
    // On the first pass: the incoming list is keyed by the local spelling.
    expect(cloud.renamedForEveryone, [('7', 'Renamed')]);
    await engine!.tick();

    expect(engine!.incoming.keys, ['Documents/Renamed']);

    expect(cloud.renamedForEveryone, [('7', 'Renamed')]);
    // The fake's rename for everyone is its only move.
    expect(cloud.moves, ['Documents/Trip? -> Documents/Renamed']);
    expect(cloud.made, isEmpty, reason: 'no ordinary folder is created');
    expect(cloud.directories, isNot(contains('Documents/Trip?')));
    expect(cloud.files.keys, ['Documents/Renamed/a.txt']);
  });
}
