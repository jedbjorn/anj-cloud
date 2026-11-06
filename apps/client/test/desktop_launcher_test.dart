import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/platform/linux/desktop_launcher.dart';
import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

import 'fakes.dart';
import 'test_platform.dart';

void main() {
  late Directory fixture;
  late RootTree tree;
  late String identity;
  late List<Uri> launched;
  late PlatformDesktopLauncher launcher;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('anj-directory-launch-');
    final parent = Directory('${fixture.path}/files')..createSync();
    tree = RootTree.setup(parent.path, 'launch-fixture', NativeRootFs());
    identity = tree.native.identity(tree.fd);
    launched = [];
    // The shared launcher's checks, with folders enabled as every desktop
    // adapter that opens folders configures it (Linux; macOS from M3), so
    // the same checks run on each seat.
    launcher = PlatformDesktopLauncher(
      directorySupported: true,
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
    );
  });
  tearDown(() {
    tree.close();
    fixture.deleteSync(recursive: true);
  });
  test('existing directory launches encoded directory URI without storage mutation', () async {
    const relative = 'Documents/space % # folder';
    tree.ensureDirectory(relative);
    final before = await tree.snapshot();
    expect(tree.directoryLocation(relative), '${tree.root.path}/$relative');
    expect(
      await launcher.openDirectory(tree.root.path, relative, identity),
      true,
    );
    expect(launched.single.toFilePath(), '${tree.root.path}/$relative/');
    expect((await tree.snapshot()).keys, before.keys);
  });
  test('missing cloud folder, file, traversal and symlink are refused without creation', () async {
    final outside = Directory('${fixture.path}/outside')..createSync();
    Link('${tree.root.path}/Documents/alias').createSync(outside.path);
    File('${tree.root.path}/Documents/file.txt')
        .writeAsStringSync('owned fixture');
    for (final relative in [
      'Documents/absent',
      'Documents/file.txt',
      '../outside',
      '/tmp',
      'Documents/alias',
    ]) {
      expect(
        () => tree.directoryLocation(relative),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        launcher.openDirectory(tree.root.path, relative, identity),
        throwsA(isA<FileSystemException>()),
      );
    }
    expect(launched, isEmpty);
    expect(Directory('${tree.root.path}/Documents/absent').existsSync(), false);
    expect(outside.listSync(), isEmpty);
  });
  test('replaced root is refused by worker boundary and immediately before platform launch', () async {
    tree.root.renameSync('${tree.root.path}-old');
    Directory('${tree.root.path}/Music').createSync(recursive: true);
    expect(
      () => tree.directoryLocation('Music'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      launcher.openDirectory(tree.root.path, 'Music', identity),
      throwsA(isA<FileSystemException>()),
    );
    expect(launched, isEmpty);
  });
  test(
    'unqualified platform is explicit and launch failure is shown safely',
    () async {
      final unavailable = PlatformDesktopLauncher(
        directorySupported: false,
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      await expectLater(
        unavailable.openDirectory(tree.root.path, 'Music', identity),
        throwsA(isA<UnsupportedError>()),
      );
      expect(launched, isEmpty);
      final controller = ClientController(
        Directory('${fixture.path}/unused'),
        secrets: MemorySecrets(),
        nativeLibrary: testNativeLibrary,
      );
      await controller.openOnDesktop(() async => false, directory: true);
      expect(
        controller.folderMessage,
        contains('Could not open the local folder'),
      );
      expect(
        controller.folderMessage,
        contains('Storage choices are unchanged'),
      );
      controller.dispose();
    },
  );
  test('worker directory action reaches injected launcher without changing retention', () async {
    final profile = Directory('${fixture.path}/profile');
    final store = Manifest(profile);
    store.setSetting('profileId', 'launch-fixture');
    store.setSetting('root', tree.root.path);
    store.setSetting('staging', tree.staging.path);
    store.setSetting('rootIdentity', tree.native.rootInfo(tree.fd).identity);
    store.setSetting('retention', 'cloud');
    store.close();
    final opened = Completer<Uri>();
    final controller = ClientController(
      profile,
      secrets: MemorySecrets(),
      launcher: PlatformDesktopLauncher(
        directorySupported: true,
        launch: (uri) async {
          opened.complete(uri);
          return true;
        },
      ),
      nativeLibrary: testNativeLibrary,
    );
    try {
      await controller.initialize();
      controller.command('openDirectory', 'Music');
      expect(
        (await opened.future.timeout(const Duration(seconds: 5))).toFilePath(),
        '${tree.root.path}/Music/',
      );
      final unavailable = Completer<void>();
      void listen() {
        if (controller.folderMessage != null && !unavailable.isCompleted) {
          unavailable.complete();
        }
      }

      controller.addListener(listen);
      controller.command('openDirectory', 'Music/missing-cloud-folder');
      await unavailable.future.timeout(const Duration(seconds: 5));
      expect(controller.folderMessage, contains('Local folder unavailable'));
      expect(
        Directory('${tree.root.path}/Music/missing-cloud-folder').existsSync(),
        false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(controller.folderMessage, contains('Local folder unavailable'));
      controller.removeListener(listen);
      await controller.stop();
      final after = Manifest(profile);
      expect(after.setting('retention'), 'local');
      // The legacy Cloud root migrated; Music itself stays Local (spec #34
      // P7), and opening it changed nothing.
      expect(after.entries['Music']?.override, isNull);
      expect(
        after.operations.values.any((operation) => operation.kind == 'working'),
        false,
      );
      after.close();
    } finally {
      await controller.stop();
      controller.dispose();
    }
  });
}
