// The macOS adapters (spec #31) on any host: start at login is the install
// manager's command (M6), the M3 ports are the macOS ones, and the root
// filesystem binds the given dylib (test_macos/ runs it for real).
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/ports/change_watcher.dart';
import 'package:anj_cloud/core/ports/root_filesystem.dart';
import 'package:anj_cloud/platform/linux/desktop_launcher.dart';
import 'package:anj_cloud/platform/linux/manager_autostart.dart';
import 'package:anj_cloud/platform/macos/keychain_secrets.dart';
import 'package:anj_cloud/platform/macos/macos_change_watchers.dart';
import 'package:anj_cloud/platform/macos/macos_desktop_session.dart';
import 'package:anj_cloud/platform/macos/macos_native_library.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/macos/macos_root_location.dart';

/// The macOS watcher never touches the filesystem; any call would fail.
class _UntouchedFs implements RootFilesystem {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the macOS watcher must not use the filesystem');
}

void main() {
  const adapters = MacosPlatformAdapters();

  test('start at login is the manager command (M6); M3 ports are macOS', () {
    expect(
      adapters.managerAutostart('/A/AnJ Cloud.app/Contents/Resources/m.sh'),
      isA<ManagerAutostart>().having(
        (m) => m.command,
        'command',
        '/A/AnJ Cloud.app/Contents/Resources/m.sh',
      ),
    );
    expect(adapters.secretStore(), isA<KeychainSecrets>());
    expect(adapters.rootLocationPolicy(), isA<MacosRootLocation>());
    expect(adapters.desktopLauncher(), isA<PlatformDesktopLauncher>());
  });

  test('the root filesystem loads the dylib it is given, nothing else', () {
    // On a Linux host the path does not exist; the binding is attempted
    // (no UnsupportedError) and fails to load, with no fallback library.
    expect(
      () => adapters.rootFilesystem('/nonexistent/libanj_rootfs.dylib'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'the session is the macOS one; a direct second launch exits 73',
    () async {
      final session = adapters.desktopSession();
      expect(session, isA<MacosDesktopSession>());
      expect(await session.activateExisting('/profile'), false);
    },
  );

  test('the dylib is loaded from the bundle, never from the environment', () {
    expect(
      macosNativeLibraryPath(
        executable:
            '/Users/u/Applications/AnJ Cloud.app/Contents/MacOS/AnJ Cloud',
      ),
      '/Users/u/Applications/AnJ Cloud.app/Contents/Frameworks/libanj_rootfs.dylib',
    );
  });

  test(
    'a filesystem without the native watch ABI keeps the stat scan',
    () async {
      final fs = _UntouchedFs();
      for (final ChangeWatcherFactory factory in [
        adapters,
        const MacosChangeWatchers(),
      ]) {
        expect(factory.watchReportsChanges(fs, 3, ''), false);
        expect(
          await factory.changeWatcher(fs, 3, '/root', const WatcherSettings()),
          isNull,
        );
      }
    },
  );
}
