import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/app/add_files.dart';
import 'core/app/controller.dart';
import 'core/app/network_transfer_policy.dart';
import 'core/app/pairing_inputs.dart';
import 'core/sync/first_sync.dart';
import 'core/update/app_updater.dart';
import 'core/update/update_blocker.dart';
import 'platform/adapters.dart';
import 'platform/android/android_add_files.dart';
import 'platform/android/android_package_installer.dart';
import 'platform/android/android_phone_folders.dart';
import 'ui/app.dart';

/// App-private storage layout on Android (spec #28 Storage and Access), all
/// under the app's files directory as its canonical path (decision #123
/// (5)): the root `<files>/anj-cloud`, its private staging
/// `<files>/.anj-cloud-<profileId>` beside it (RootTree.setup) and the
/// profile `<files>/anj-profile/default` (`AndroidSession.defaultProfile`),
/// which holds manifest.sqlite.
class MobileStorage {
  MobileStorage(this.files);
  final String files;
  String get rootParent => files;

  /// The updater's downloads, in app-private cache (spec #28 A7).
  static Future<Directory> updates() async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'anj-updates'),
  );

  static Future<MobileStorage> locate() async => MobileStorage(
    (await getApplicationSupportDirectory()).resolveSymbolicLinksSync(),
  );
}

/// The runner's device channel (android/.../SyncHost.kt).
const _device = MethodChannel('cloud.anj/device');

/// Pairing on Android (spec #28 Pairing, adopting spec #35): the household
/// server prefilled and the pairing code typed or scanned live from a QR
/// code carrying it (#108 Q12), no CA file and no fingerprint step; the
/// first-sync folder screen with every folder Cloud by default (#108 Q2,
/// #118) and the phone's own name as label.
final androidPairing = PairingOptions(
  liveScan: true,
  firstSync: FirstSyncDefault.cloud,
  deviceLabel: () async =>
      await _device.invokeMethod<String>('label') ?? 'Android phone',
);

/// The Android entry (spec #28 Shared seams): no command-line arguments, no
/// tray and no window lifecycle, the same [ClientController] as the desktop
/// entry. The engine runs once per process (SyncHost in the Android runner),
/// so the profile lock only guards against a second process.
Future<void> mobileMain() async {
  final storage = await MobileStorage.locate();
  final adapters = platformAdapters();
  final session = adapters.desktopSession();
  final Directory profile;
  try {
    profile = session
        .acquireProfile(session.defaultProfile(storage.files))
        .profile;
  } catch (error) {
    runApp(_Refused(error is FileSystemException ? error.message : '$error'));
    return;
  }
  // "Wi-Fi only" is the Android default (decision #108 Q4).
  final controller = ClientController(
    profile,
    pairingOptions: androidPairing,
    defaultNetworkPolicy: 'wifi',
    // Music, Videos and Documents in the phone's own folders (spec #52).
    phoneFolders: const AndroidPhoneFolders(),
  );
  // Background runs, connectivity and notifications (spec #28 A4). The
  // handler is installed before the worker starts; a WorkManager run that
  // started this process is answered once setup has finished.
  final initialized = Completer<void>();
  final mobile = mobileSettings(controller);
  unawaited(mobile?.start(initialized.future));
  // The in-app updater (spec #28 A7): checks the household server when the
  // app opens and every few hours; installs only after the user approves.
  // Its download is a transfer: it waits under "Wi-Fi only" (A4, #108 Q4).
  // The install waits, as on desktop, until no file is moving and no Finish
  // editing is pending: installing restarts the app (review M3).
  final updater = AppUpdater(
    feed: ControllerUpdateFeed(controller),
    installer: const AndroidPackageInstaller(),
    downloads: await MobileStorage.updates(),
    policy: NetworkSettingPolicy(controller),
    blocker: () => controllerUpdateBlocker(controller),
    busySignal: controller,
  )..start();
  // Opening the app lists the cloud and verifies every local file
  // (decision #130 (3)); the worker treats it as the window being shown.
  _keepAlive.add(
    AppLifecycleListener(
      onResume: () {
        // All files access first: coming back from its settings page
        // resumes the phone folders with a full verification (spec #52).
        unawaited(controller.checkPhoneFolders());
        controller.windowShown(verify: true);
        unawaited(updater.resumed());
      },
      // Android's install confirmation in front, or the user elsewhere.
      onInactive: updater.left,
    ),
  );
  // The "AnJ Cloud" documents provider and its allowlist (spec #28 A5).
  final access = adapters.startDocuments(controller, profile.path);
  // Folder ⋮ → Add files… / Add folder… and the Share sheet (spec #43):
  // the system picker's grant; the copy is a worker command.
  final addFiles = AddFiles(
    AndroidAddFiles(),
    command: controller.documentsCommand,
    cancelWorker: controller.cancelAdd,
    root: () => controller.root,
  );
  // No root picker on Android: the root is fixed app-private storage.
  // Touch input: rows open on tap, long-press for the icon colour.
  runApp(
    CloudApp(
      controller: controller,
      rootPicker: false,
      touchInput: true,
      autostart: adapters.managerAutostart(''),
      autostartLabel: 'Background sync',
      mobile: mobile,
      androidUpdater: updater,
      appAccess: access,
      addFiles: addFiles,
    ),
  );
  try {
    await controller.initialize();
    // The root is fixed on Android: app-private storage, never a picker.
    if (controller.root == null) {
      await controller.configureRoot(storage.rootParent);
    }
  } catch (_) {
    controller.reportMessage(
      'Client setup could not start. Check app storage and the Android filesystem adapter.',
    );
  } finally {
    initialized.complete();
  }
}

/// Kept for the process lifetime.
final _keepAlive = <Object>[];

class _Refused extends StatelessWidget {
  const _Refused(this.reason);
  final String reason;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AnJ Cloud',
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('AnJ Cloud could not open its profile: $reason'),
        ),
      ),
    ),
  );
}
