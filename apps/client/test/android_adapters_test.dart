// Spec #28 A2: the Android adapter set, exercised on Linux against the Linux
// build of the same anj_* ABI (the Android library is the same source, see
// test/android_boundary_test.dart). The on-device run of these seams is
// integration_test/android_engine_test.dart.
import 'dart:io';

import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_platform_adapters.dart';
import 'package:anj_cloud/platform/android/android_root_fs.dart';
import 'package:anj_cloud/platform/android/android_session.dart';
import 'package:anj_cloud/platform/android/background.dart';
import 'package:anj_cloud/platform/android/keystore_secrets.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/linux/linux_platform_adapters.dart';
import 'package:anj_cloud/platform/native/local_watcher.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture;
  setUp(() => fixture = Directory.systemTemp.createTempSync('anj-android-'));
  tearDown(() => fixture.deleteSync(recursive: true));

  test('both selectors pick the same platform', () {
    if (Platform.isLinux) {
      expect(platformAdapters(), isA<LinuxPlatformAdapters>());
      expect(platformWatchers(), isA<LinuxChangeWatchers>());
    } else if (Platform.isAndroid) {
      expect(platformAdapters(), isA<AndroidPlatformAdapters>());
      expect(platformWatchers(), isA<AndroidChangeWatchers>());
    }
  });

  test(
    'the Android set: its own filesystem, keystore, session, background switch',
    () {
      const adapters = AndroidPlatformAdapters();
      final fs = adapters.rootFilesystem(
        Platform.environment['ANJ_ROOTFS_LIBRARY'],
      );
      expect(fs, isA<AndroidRootFs>());
      expect(fs, isA<NativeRootFs>());
      expect(adapters.secretStore(), isA<KeystoreSecrets>());
      expect(adapters.desktopSession(), isA<AndroidSession>());
      // Start at login is the Background-sync switch (spec #28 A4).
      expect(adapters.managerAutostart('x'), isA<AndroidBackgroundSwitch>());
    },
  );

  test(
    'the root filesystem reports no writeback: the fast path is off',
    () async {
      final fs = AndroidRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']);
      expect(fs.writeback(), isNull);
      if (Platform.isLinux) {
        expect(
          NativeRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']).writeback(),
          isNotNull,
          reason: 'the VM host can read /proc/sys/vm',
        );
      }
      // The test seam still reads a fixture directory.
      final vm = Directory('${fixture.path}/vm')..createSync();
      File('${vm.path}/dirty_expire_centisecs').writeAsStringSync('3000\n');
      File('${vm.path}/dirty_writeback_centisecs').writeAsStringSync('500\n');
      File('${vm.path}/laptop_mode').writeAsStringSync('0\n');
      expect(fs.writeback(directory: vm.path), (
        expireCentisecs: 3000,
        writebackCentisecs: 500,
        laptopMode: 0,
      ));
      final tree = RootTree.setup(fixture.path, 'android', fs);
      try {
        File('${tree.root.path}/Documents/a.txt').writeAsStringSync('a');
        final items = await tree.snapshot();
        expect(tree.writebackEnabled, isFalse);
        expect(items['Documents/a.txt']!.hash, isNotNull);
        expect(
          items['Documents/a.txt']!.stamp,
          isNull,
          reason: 'no stamp is stored while hashes are not reused',
        );
      } finally {
        tree.close();
      }
    },
  );

  test('the watcher is the shared inotify watcher', () async {
    final fs = AndroidRootFs(Platform.environment['ANJ_ROOTFS_LIBRARY']);
    final tree = RootTree.setup(fixture.path, 'android', fs);
    ChangeWatcher? watcher;
    try {
      const watchers = AndroidChangeWatchers();
      expect(watchers.watchReportsChanges(fs, tree.fd, ''), isTrue);
      watcher = await watchers.changeWatcher(
        fs,
        tree.fd,
        tree.root.path,
        const WatcherSettings(),
      );
      expect(watcher, isA<LocalWatcher>());
    } finally {
      watcher?.close();
      tree.close();
    }
  });

  test('the session has a profile lock and no tray', () async {
    final session = AndroidSession();
    final lock = session.acquireProfile('${fixture.path}/profile');
    expect(lock.profile.existsSync(), isTrue);
    expect(
      () => session.acquireProfile('${fixture.path}/profile'),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await session.startTray(
        onOpen: () {},
        onTogglePause: () {},
        onQuit: () {},
      ),
      isNull,
    );
    expect(await session.activateExisting(lock.profile.path), isFalse);
  });
}
