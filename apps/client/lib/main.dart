import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'core/app/controller.dart';
import 'core/app/lifecycle.dart';
import 'core/local/root_move.dart';
import 'core/ports/platform_adapters.dart';
import 'core/ports/desktop_session.dart';
import 'core/state/manifest.dart';
import 'core/update/desktop_updater.dart';
import 'core/update/release.dart';
import 'mobile_main.dart';
import 'platform/adapters.dart';
import 'ui/app.dart';

/// Kept for the process lifetime: window close requests and signals.
final _keepAlive = <Object>[];

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) return mobileMain();
  return desktopMain(arguments);
}

/// The desktop entry: command-line arguments, the profile lifetime lock, the
/// tray and the window lifecycle (spec #28 Shared seams).
Future<void> desktopMain(List<String> arguments) async {
  String? profile;
  String? managerCommand;
  String? defaultRoot;
  var background = false;
  var inheritedLock = -1;
  var inheritedSeen = false;
  String? moveRoot;
  final knownRoots = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--profile-dir' && i + 1 < arguments.length) {
      if (profile != null) throw ArgumentError('Duplicate --profile-dir');
      profile = arguments[++i];
    } else if (arguments[i] == '--background') {
      // Login start: hidden in the tray when one appears (runner too).
      background = true;
    } else if (arguments[i] == '--manager-command' &&
        i + 1 < arguments.length) {
      if (managerCommand != null) {
        throw ArgumentError('Duplicate --manager-command');
      }
      managerCommand = arguments[++i];
    } else if (arguments[i] == '--default-root' && i + 1 < arguments.length) {
      // The root the installer reserved for a new profile (select-profile
      // --new --root); without it a new profile's root is the home folder.
      if (defaultRoot != null) throw ArgumentError('Duplicate --default-root');
      defaultRoot = arguments[++i];
    } else if (arguments[i] == '--move-root' && i + 1 < arguments.length) {
      // `linux_install.py move-root`: move the synced folder, print the
      // outcome as JSON and exit; no window, tray or sync (runner too).
      if (moveRoot != null) throw ArgumentError('Duplicate --move-root');
      moveRoot = arguments[++i];
    } else if (arguments[i] == '--known-root' && i + 1 < arguments.length) {
      knownRoots.add(arguments[++i]);
    } else if (arguments[i] == '--profile-lock-fd' &&
        i + 1 < arguments.length) {
      if (inheritedSeen) throw ArgumentError('Duplicate --profile-lock-fd');
      inheritedSeen = true;
      inheritedLock = int.parse(arguments[++i]);
      if (inheritedLock < 3) {
        throw ArgumentError('Invalid profile lock descriptor');
      }
    } else {
      throw ArgumentError(
        'Supported options: --profile-dir <private state directory>, --default-root <folder for a new profile\'s anj-cloud>, --background',
      );
    }
  }
  // A Windows manager install keeps its manager beside the client; the
  // shortcut and the Run value (260-character limit) pass no command.
  if (managerCommand == null && Platform.isWindows) {
    final beside = File(
      '${File(Platform.resolvedExecutable).parent.path}\\anj-cloud-manager.exe',
    );
    if (beside.existsSync()) managerCommand = beside.path;
  }
  // macOS: the install manager is embedded in the bundle (spec #31 M6), so
  // a Finder, Dock or LaunchAgent start finds it without an argument.
  if (managerCommand == null && Platform.isMacOS) {
    final embedded = File(
      '${File(Platform.resolvedExecutable).parent.parent.path}'
      '/Resources/anj-cloud-macos-install.sh',
    );
    if (embedded.existsSync()) managerCommand = embedded.path;
  }
  final adapters = platformAdapters();
  final session = adapters.desktopSession();
  final support =
      profile ??
      session.defaultProfile((await getApplicationSupportDirectory()).path);
  // Acquire before runApp, Manifest or keyring access. Native CLOEXEC prevents
  // external editors from retaining the lifetime lock after this app exits.
  late final ProfileLock lifetime;
  try {
    lifetime = session.acquireProfile(support, inherited: inheritedLock);
  } catch (error) {
    if (moveRoot != null) {
      await _moveRootOutcome(2, {
        'refused':
            'AnJ Cloud is running for this profile. Quit it (tray or app '
            'menu: Quit), then run move-root again. Nothing was changed.',
      });
    }
    // Re-launch while running: show the existing window, never a second
    // process on this profile.
    if (error is ProfileInUseException &&
        !background &&
        await session.activateExisting(error.path)) {
      stdout.writeln(
        'anj-cloud: already running for this profile; its window was shown.',
      );
      exit(0);
    }
    stderr.writeln('anj-cloud: $error');
    exit(73);
  }
  if (moveRoot != null) {
    await _moveRoot(lifetime.profile, adapters, moveRoot, knownRoots);
  }
  final controller = ClientController(
    lifetime.profile,
    placement: adapters.rootPlacement(reservedParent: defaultRoot),
  );
  final notices = LifecycleNotices(lifetime.profile)..load();
  late final DesktopLifecycle lifecycle;
  final tray = await session.startTray(
    onOpen: () => unawaited(lifecycle.open()),
    onTogglePause: () => controller.setPaused(!controller.paused),
    onQuit: () => unawaited(lifecycle.quit()),
  );
  lifecycle = DesktopLifecycle(
    window: session.window(),
    stopSync: controller.stop,
    tray: tray,
    onShown: controller.windowShown,
    notices: notices,
    background: background,
  );
  if (tray != null) {
    await session.claimActivation(
      lifetime.profile.path,
      () => unawaited(lifecycle.open()),
    );
  }
  controller.addListener(
    () =>
        unawaited(tray?.setState(controller.status, paused: controller.paused)),
  );
  _keepAlive.add(
    AppLifecycleListener(
      onExitRequested: () async {
        unawaited(lifecycle.closeRequested());
        return AppExitResponse.cancel;
      },
    ),
  );
  // Windows has no SIGTERM to watch (session end arrives through the
  // runner's WM_ENDSESSION instead, spec #32 W3).
  for (final signal in [
    if (!Platform.isWindows) ProcessSignal.sigterm,
    ProcessSignal.sigint,
  ]) {
    _keepAlive.add(signal.watch().listen((_) => unawaited(lifecycle.quit())));
  }
  // Spec #37: a manager-launched build updates itself through its manager.
  final selfUpdate = managerCommand == null
      ? null
      : adapters.managerSelfUpdate(managerCommand);
  final updater = selfUpdate == null
      ? null
      : DesktopUpdater(
          feed: ControllerUpdateFeed(controller),
          port: selfUpdate,
          directory: Directory('${lifetime.profile.path}/updates'),
          loadKey: () async {
            try {
              return await rootBundle.loadString(ReleaseKey.asset);
            } on Object {
              return null;
            }
          },
          quit: lifecycle.quit,
          blocker: () => controllerUpdateBlocker(controller),
          busySignal: controller,
        );
  runApp(
    CloudApp(
      controller: controller,
      lifecycle: lifecycle,
      notices: notices,
      autostart: managerCommand == null
          ? null
          : adapters.managerAutostart(managerCommand),
      updater: updater,
    ),
  );
  unawaited(updater?.start());
  unawaited(lifecycle.start());
  try {
    await controller.initialize();
  } catch (_) {
    controller.reportMessage(
      'Client setup could not start. Check private state permissions and the Linux filesystem adapter.',
    );
  }
}

/// `--move-root <target>` (Linux `linux_install.py move-root`): moves the
/// profile's synced folder with [RootMover] while this process holds the
/// profile's lifetime lock, prints one JSON line and exits: 0 moved (or
/// already there), 2 refused, 1 failed.
Future<Never> _moveRoot(
  Directory profile,
  PlatformAdapters adapters,
  String target,
  List<String> knownRoots,
) async {
  final placement = adapters.rootPlacement();
  Manifest? store;
  try {
    store = Manifest(profile);
    final outcome = await RootMover(
      store,
      profile.path,
      adapters.rootFilesystem(),
      desktop: placement.desktopDirectory(),
      keep: placement.keptDirectories(),
      knownRoots: knownRoots,
    ).move(target);
    store.close();
    return await _moveRootOutcome(0, outcome);
  } on RootMoveRefused catch (error) {
    store?.close();
    return await _moveRootOutcome(2, {
      'refused': error.message,
      'entries': error.entries,
      'journal_kept': error.journalKept,
    });
  } catch (error) {
    try {
      store?.close();
    } on Object {
      // Exiting: the process releases the database.
    }
    return await _moveRootOutcome(1, {'error': '$error'});
  }
}

Future<Never> _moveRootOutcome(int code, Map<String, Object?> outcome) async {
  stdout.writeln(jsonEncode(outcome));
  await stdout.flush();
  exit(code);
}
