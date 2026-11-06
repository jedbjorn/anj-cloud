import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

void main(List<String> arguments) {
  if (arguments.length != 1 || Directory(arguments.single).existsSync()) {
    throw ArgumentError('Supply one absent, disposable fixture directory.');
  }
  final fixture = Directory(arguments.single)..createSync(recursive: true);
  final native = NativeRootFs();
  native.privateDir(fixture.path);
  for (final name in ['a', 'b']) {
    final profile = Directory('${fixture.path}/profile-$name');
    profile.createSync();
    native.privateDir(profile.path);
    final parent = Directory('${fixture.path}/files-$name')..createSync();
    final tree = RootTree.setup(parent.path, 'fixture-$name', native);
    final manifest = Manifest(profile);
    manifest.setSetting('profileId', 'fixture-$name');
    manifest.setSetting('root', tree.root.path);
    manifest.setSetting('rootIdentity', native.rootInfo(tree.fd).identity);
    manifest.setSetting('staging', tree.staging.path);
    manifest.setSetting('retention', name == 'a' ? 'local' : 'cloud');
    tree.ensureDirectory('Documents/Fixture notes');
    File(
      '${tree.root.path}/Documents/Fixture notes/hello.txt',
    ).writeAsStringSync(
      'Synthetic anj-cloud acceptance fixture. No personal files enrolled.\n',
    );
    manifest.close();
    tree.close();
    stdout.writeln(profile.path);
  }
}
