import 'dart:io';

import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/linux/linux_platform_adapters.dart';
import 'package:anj_cloud/platform/linux/manager_autostart.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:anj_cloud/platform/windows/windows_platform_adapters.dart';
import 'package:anj_cloud/platform/windows/windows_root_fs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_platform.dart';

/// Spec #32 W0: the Windows adapter skeleton and the committed runner. Runs
/// on Linux (check.sh) and on the Windows seat (tool/windows/build.ps1).
void main() {
  const adapters = WindowsPlatformAdapters();

  test('the selectors pick the running platform', () {
    if (Platform.isWindows) {
      expect(platformAdapters(), isA<WindowsPlatformAdapters>());
      expect(platformWatchers(), isA<WindowsChangeWatchers>());
    } else if (Platform.isLinux) {
      expect(platformAdapters(), isA<LinuxPlatformAdapters>());
      expect(platformWatchers(), isA<LinuxChangeWatchers>());
    }
  });

  test('start at login goes through the installed manager (W5)', () {
    expect(
      adapters.managerAutostart(r'C:\m\anj-cloud-manager.exe'),
      isA<ManagerAutostart>(),
    );
  });

  test('the root filesystem loads anj_rootfs.dll beside the executable', () {
    expect(
      windowsRootfsLibrary(
        executable:
            r'C:\Users\u\AppData\Local\Programs\anj-cloud\anj_cloud.exe',
        environment: const {},
      ),
      r'C:\Users\u\AppData\Local\Programs\anj-cloud\anj_rootfs.dll',
    );
    expect(
      windowsRootfsLibrary(
        executable: r'C:\x\anj_cloud.exe',
        environment: const {'ANJ_ROOTFS_LIBRARY': r'C:\build\anj_rootfs.dll'},
      ),
      r'C:\build\anj_rootfs.dll',
    );
  });

  test(
    'a root filesystem outside the shared binding gets no watcher',
    () async {
      final fs = _NoFs();
      expect(adapters.watchReportsChanges(fs, 3, ''), isFalse);
      expect(
        await adapters.changeWatcher(fs, 3, 'root', const WatcherSettings()),
        isNull,
      );
    },
  );

  group('committed runner', () {
    String read(String path) => File(path).readAsStringSync();

    test('builds anj_cloud.exe titled AnJ Cloud', () {
      expect(
        read('windows/CMakeLists.txt'),
        contains('set(BINARY_NAME "anj_cloud")'),
      );
      expect(
        read('windows/runner/main.cpp'),
        contains('window.Create(L"AnJ Cloud"'),
      );
    });

    test('declares long path awareness and per-monitor DPI', () {
      final manifest = read('windows/runner/runner.exe.manifest');
      expect(
        manifest,
        matches(RegExp(r'<longPathAware[^>]*>true</longPathAware>')),
      );
      expect(manifest, contains('PerMonitorV2'));
    });

    test('registers the Windows plugins the client depends on', () {
      final plugins = read('windows/flutter/generated_plugins.cmake');
      for (final plugin in [
        'file_selector_windows',
        'flutter_secure_storage_windows',
        'url_launcher_windows',
      ]) {
        expect(plugins, contains(plugin));
      }
    });
  }, skip: checkoutFile('windows/CMakeLists.txt'));
}

class _NoFs implements RootFilesystem {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
