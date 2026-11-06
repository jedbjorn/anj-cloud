// platformAdapters() and platformWatchers() must pick the same platform
// (flag SC-045 F3): the sync engine reaches the watcher through
// platformWatchers(), everything else through platformAdapters().
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/android/android_change_watchers.dart';
import 'package:anj_cloud/platform/android/android_platform_adapters.dart';
import 'package:anj_cloud/platform/linux/linux_change_watchers.dart';
import 'package:anj_cloud/platform/linux/linux_platform_adapters.dart';
import 'package:anj_cloud/platform/macos/macos_change_watchers.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/watchers.dart';
import 'package:anj_cloud/platform/windows/windows_change_watchers.dart';
import 'package:anj_cloud/platform/windows/windows_platform_adapters.dart';

class _UntouchedFs implements RootFilesystem {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('an absent watcher must not use the filesystem');
}

void main() {
  test('both selectors pick the running platform', () {
    if (Platform.isLinux) {
      expect(platformAdapters(), isA<LinuxPlatformAdapters>());
      expect(platformWatchers(), isA<LinuxChangeWatchers>());
    } else if (Platform.isMacOS) {
      expect(platformAdapters(), isA<MacosPlatformAdapters>());
      expect(platformWatchers(), isA<MacosChangeWatchers>());
    } else if (Platform.isWindows) {
      expect(platformAdapters(), isA<WindowsPlatformAdapters>());
      expect(platformWatchers(), isA<WindowsChangeWatchers>());
    } else if (Platform.isAndroid) {
      expect(platformAdapters(), isA<AndroidPlatformAdapters>());
      expect(platformWatchers(), isA<AndroidChangeWatchers>());
    } else {
      expect(platformAdapters, throwsUnsupportedError);
      expect(platformWatchers(), isA<UnwatchedChangeWatchers>());
    }
  });

  test(
    'a platform without a watcher keeps the stat scan, never throws',
    () async {
      const unwatched = UnwatchedChangeWatchers();
      final fs = _UntouchedFs();
      expect(unwatched.watchReportsChanges(fs, 3, ''), false);
      expect(
        await unwatched.changeWatcher(fs, 3, '/root', const WatcherSettings()),
        isNull,
      );
    },
  );
}
