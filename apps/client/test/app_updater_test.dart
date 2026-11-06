// Spec #28 A7: the in-app updater's decisions with a fake feed and a fake
// package installer. Every refusal must discard the download before the
// installer is asked anything; nothing installs without the user.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/ports/package_installer.dart';
import 'package:anj_cloud/core/ports/transfer_policy.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/update/app_updater.dart';
import 'package:anj_cloud/core/update/release.dart';
import 'package:anj_cloud/ui/update_panel.dart';

const pkg = 'cloud.anj.anj_cloud.qa';
final key = 'a1' * 32;
final otherKey = 'b2' * 32;

ReleaseManifest release({int code = 2, String? signer}) => ReleaseManifest(
  target: androidReleaseTarget,
  version: '0.$code.0',
  versionCode: code,
  size: 4,
  sha256: 'cc' * 32,
  signerSha256: signer ?? key,
);

PackageFacts facts({int code = 1, Set<String>? signers, String name = pkg}) =>
    PackageFacts(
      packageName: name,
      versionCode: code,
      versionName: '0.$code.0',
      signers: signers ?? {key},
    );

class FakeFeed extends ChangeNotifier implements UpdateFeed {
  @override
  bool ready = true;
  ReleaseManifest? served;
  Object? checkError;
  Object? downloadError;
  int downloads = 0;
  int checks = 0;

  /// When set, a download stays in progress until cancelled or completed.
  Completer<void>? hold;
  @override
  Future<ReleaseManifest?> latest(String target) async {
    checks++;
    expect(target, androidReleaseTarget);
    if (checkError != null) throw checkError!;
    return served;
  }

  @override
  Future<void> download(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
  }) async {
    downloads++;
    destination.writeAsStringSync('apk!');
    progress?.call(4);
    final waiting = hold;
    if (waiting != null) {
      try {
        await waiting.future;
      } catch (_) {
        destination.deleteSync();
        rethrow;
      }
    }
    if (downloadError != null) {
      destination.deleteSync();
      throw downloadError!;
    }
  }

  int cancels = 0;
  @override
  void cancelDownload() {
    cancels++;
    final waiting = hold;
    hold = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(const ReleaseCancelled());
    }
  }
}

class FakeInstaller implements PackageInstallerPort {
  PackageFacts current = facts();
  PackageFacts? archive = facts(code: 2);
  bool allowed = true;
  InstallOutcome outcome = InstallOutcome.declined;
  final installs = <String>[];
  final inspected = <String>[];
  int permissionScreens = 0;
  int? free;
  int discarded = 0;
  int cancels = 0;

  /// When set, Android's confirmation stays unanswered.
  Completer<InstallResult>? confirmation;
  @override
  Future<PackageFacts> installed() async => current;
  @override
  Future<int?> freeBytes(String path) async => free;
  @override
  Future<void> discardSessions() async => discarded++;
  @override
  Future<void> cancelInstall() async {
    cancels++;
    final waiting = confirmation;
    confirmation = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(
        const InstallResult(InstallOutcome.declined, 'cancelled'),
      );
    }
  }

  @override
  Future<PackageFacts?> inspect(String path) async {
    inspected.add(path);
    expect(File(path).existsSync(), isTrue);
    return archive;
  }

  @override
  Future<bool> canRequestInstalls() async => allowed;
  @override
  Future<void> openInstallPermission() async => permissionScreens++;
  @override
  Future<InstallResult> install(
    String path, {
    required String sha256,
    required int size,
  }) async {
    expect(File(path).existsSync(), isTrue);
    installs.add(path);
    final waiting = confirmation;
    if (waiting != null) return waiting.future;
    return InstallResult(outcome);
  }
}

/// The controller's sync state as the install sees it.
class Busy extends ChangeNotifier {
  String? reason = 'files finish syncing';
  void set(String? next) {
    reason = next;
    notifyListeners();
  }
}

class Blocked implements TransferPolicy {
  String? reason = 'Waiting for Wi-Fi';
  @override
  Future<String?> transferBlocked() async => reason;
}

void main() {
  late Directory downloads;
  late FakeFeed feed;
  late FakeInstaller installer;
  late DateTime now;
  AppUpdater make({
    TransferPolicy policy = const AnyNetworkPolicy(),
    Duration installGrace = const Duration(seconds: 60),
    Busy? busy,
    Duration policyRecheck = const Duration(seconds: 5),
  }) => AppUpdater(
    feed: feed,
    installer: installer,
    downloads: downloads,
    policy: policy,
    installGrace: installGrace,
    blocker: busy == null ? null : () => busy.reason,
    busySignal: busy,
    policyRecheck: policyRecheck,
    now: () => now,
  );
  List<FileSystemEntity> kept() => downloads.listSync();

  setUp(() {
    downloads = Directory.systemTemp.createTempSync('anj-updates-');
    feed = FakeFeed()..served = release();
    installer = FakeInstaller();
    now = DateTime.utc(2026, 11, 4, 12);
  });
  tearDown(() => downloads.deleteSync(recursive: true));

  test('opening checks once; an available update downloads nothing', () async {
    File('${downloads.path}/stale.apk').writeAsStringSync('old');
    feed.ready = false;
    final updater = make()..start();
    expect(kept(), isEmpty, reason: 'start clears earlier downloads');
    expect(feed.checks, 0);
    feed
      ..ready = true
      ..notifyListeners();
    await pumpEventQueue();
    expect(feed.checks, 1);
    expect(updater.phase, UpdatePhase.available);
    expect(updater.manifest, release());
    expect(feed.downloads, 0);
    expect(installer.installs, isEmpty);
    // Opening again soon after does not ask again; later it does.
    await updater.resumed();
    expect(feed.checks, 1);
    now = now.add(const Duration(minutes: 16));
    await updater.resumed();
    expect(feed.checks, 2);
    updater.dispose();
  });

  test('same or lower version on the server is up to date', () async {
    final updater = make();
    for (final code in [1]) {
      feed.served = release(code: code);
      await updater.check(manual: true);
      expect(updater.phase, UpdatePhase.upToDate);
    }
    feed.served = null;
    await updater.check();
    expect(updater.phase, UpdatePhase.idle);
  });

  test(
    'approve: download, verify, then Android asks; decline keeps v1',
    () async {
      final updater = make();
      await updater.check();
      installer.outcome = InstallOutcome.declined;
      await updater.downloadAndInstall();
      expect(installer.inspected, hasLength(1));
      expect(installer.installs, hasLength(1));
      expect(updater.phase, UpdatePhase.declined);
      expect(kept(), hasLength(1), reason: 'the verified file is kept');
      // Install again re-verifies before asking Android again.
      installer.outcome = InstallOutcome.installed;
      await updater.installAgain();
      expect(installer.inspected, hasLength(2));
      expect(installer.installs, hasLength(2));
      expect(updater.phase, UpdatePhase.idle);
      expect(kept(), isEmpty);
    },
  );

  group('refused before the installer opens', () {
    Future<AppUpdater> refuse(void Function() arrange, String reason) async {
      final updater = make();
      await updater.check();
      arrange();
      await updater.downloadAndInstall();
      expect(updater.phase, UpdatePhase.refused);
      expect(updater.message, contains(reason));
      expect(installer.installs, isEmpty);
      expect(kept(), isEmpty, reason: 'the download is discarded');
      return updater;
    }

    test('wrong SHA-256 (from the download)', () async {
      await refuse(
        () => feed.downloadError = const ReleaseRefused(
          "The download does not match the update's SHA-256 checksum.",
        ),
        'SHA-256',
      );
      expect(installer.inspected, isEmpty);
    });

    test('different signer than the installed app', () async {
      await refuse(
        () => installer.archive = facts(code: 2, signers: {otherKey}),
        'different key',
      );
    });

    test('a signer the manifest does not name', () async {
      feed.served = release(signer: otherKey);
      await refuse(() {}, 'signing key does not match');
    });

    test('lower or equal versionCode than installed', () async {
      installer.current = facts(code: 3);
      feed.served = release(code: 5);
      await refuse(
        () => installer.archive = facts(code: 2),
        'not newer than the installed',
      );
    });

    test('archive version differs from the manifest', () async {
      feed.served = release(code: 4);
      await refuse(() => installer.archive = facts(code: 3), 'version differs');
    });

    test('another app or an unreadable file', () async {
      await refuse(
        () => installer.archive = facts(code: 2, name: 'com.example'),
        'different app',
      );
      installer.archive = null;
      final updater = make();
      await updater.check(manual: true);
      await updater.downloadAndInstall();
      expect(updater.message, contains('not a readable Android package'));
      expect(installer.installs, isEmpty);
    });

    test(
      'an automatic check keeps the reason; a manual one re-offers',
      () async {
        final updater = await refuse(
          () => installer.archive = facts(code: 2, signers: {otherKey}),
          'different key',
        );
        await updater.check();
        expect(updater.phase, UpdatePhase.refused);
        await updater.check(manual: true);
        expect(updater.phase, UpdatePhase.available);
      },
    );
  });

  test(
    '"Install unknown apps" first, then the install continues on return',
    () async {
      installer.allowed = false;
      final updater = make();
      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.phase, UpdatePhase.permission);
      expect(installer.installs, isEmpty);
      await updater.openPermissionSettings();
      expect(installer.permissionScreens, 1);
      await updater.resumed();
      expect(
        updater.phase,
        UpdatePhase.permission,
        reason: 'still not allowed',
      );
      installer.allowed = true;
      await updater.resumed();
      expect(installer.installs, hasLength(1));
    },
  );

  test('the network setting holds the download', () async {
    final policy = Blocked();
    final updater = make(policy: policy);
    await updater.check();
    await updater.downloadAndInstall();
    expect(updater.phase, UpdatePhase.waiting);
    expect(updater.message, 'Waiting for Wi-Fi');
    expect(feed.downloads, 0);
    policy.reason = null;
    await updater.downloadAndInstall();
    expect(feed.downloads, 1);
  });

  test('leaving Wi-Fi during the download stops it (review L4)', () async {
    final policy = Blocked()..reason = null;
    feed.hold = Completer();
    final updater = make(
      policy: policy,
      policyRecheck: const Duration(milliseconds: 10),
    );
    await updater.check();
    final download = updater.downloadAndInstall();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(updater.phase, UpdatePhase.downloading, reason: 'still on Wi-Fi');
    policy.reason = 'Waiting for Wi-Fi';
    await download.timeout(const Duration(seconds: 5));
    expect(feed.cancels, 1);
    expect(updater.phase, UpdatePhase.waiting);
    expect(updater.message, 'Waiting for Wi-Fi');
    expect(kept(), isEmpty, reason: 'the partial download is discarded');
    expect(installer.inspected, isEmpty);
    policy.reason = null;
    await updater.downloadAndInstall();
    expect(feed.downloads, 2);
    expect(installer.installs, hasLength(1));
  });

  group('sync holds the install, as on desktop (review M3)', () {
    const syncing = 'Update (version 0.2.0) starts when files finish syncing…';
    const editing =
        'Update (version 0.2.0) starts when Finish editing completes…';

    test('an upload, then a Finish editing, then the install', () async {
      final busy = Busy();
      final updater = make(busy: busy);
      await updater.check();
      final install = updater.downloadAndInstall();
      await pumpEventQueue();
      // The download and its checks are not held; only the install is.
      expect(feed.downloads, 1);
      expect(installer.inspected, hasLength(1));
      expect(updater.phase, UpdatePhase.waitingForSync);
      expect(updater.message, syncing);
      expect(updater.busy, isFalse, reason: 'Later stays available');
      expect(installer.installs, isEmpty);
      busy.set('Finish editing completes');
      await pumpEventQueue();
      expect(updater.message, editing);
      expect(installer.installs, isEmpty);
      busy.set(null);
      await install;
      expect(installer.installs, hasLength(1));
      expect(updater.phase, UpdatePhase.declined);
    });

    test('Install again waits too', () async {
      final busy = Busy()..reason = null;
      final updater = make(busy: busy);
      await updater.check();
      await updater.downloadAndInstall();
      expect(updater.phase, UpdatePhase.declined);
      expect(installer.installs, hasLength(1));
      busy.set('files finish syncing');
      final again = updater.installAgain();
      await pumpEventQueue();
      expect(updater.phase, UpdatePhase.waitingForSync);
      expect(installer.installs, hasLength(1));
      busy.set(null);
      await again;
      expect(installer.installs, hasLength(2));
    });

    test('a change nobody announces is still seen', () async {
      final busy = Busy();
      final updater = make(busy: busy);
      await updater.check();
      final install = updater.downloadAndInstall();
      await pumpEventQueue();
      expect(updater.phase, UpdatePhase.waitingForSync);
      busy.reason = null; // no notification: the 1 s re-check finds it
      await install.timeout(const Duration(seconds: 5));
      expect(installer.installs, hasLength(1));
    });

    test('Later while waiting: nothing installs, the file goes', () async {
      final busy = Busy();
      final updater = make(busy: busy);
      await updater.check();
      final install = updater.downloadAndInstall();
      await pumpEventQueue();
      expect(updater.phase, UpdatePhase.waitingForSync);
      expect(kept(), hasLength(1));
      updater.dismiss();
      await install;
      busy.set(null);
      await pumpEventQueue();
      expect(installer.installs, isEmpty);
      expect(updater.phase, UpdatePhase.idle);
      expect(kept(), isEmpty);
    });

    test('an automatic check of the same release keeps waiting', () async {
      final busy = Busy();
      final updater = make(busy: busy);
      await updater.check();
      final install = updater.downloadAndInstall();
      await pumpEventQueue();
      await updater.check();
      expect(updater.phase, UpdatePhase.waitingForSync);
      busy.set(null);
      await install;
      expect(installer.installs, hasLength(1));
    });

    testWidgets('the panel says what the install waits for', (tester) async {
      final busy = Busy();
      final updater = make(busy: busy);
      await tester.runAsync(updater.check);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: UpdatePanel(updater: updater)),
        ),
      );
      late Future<void> install;
      await tester.runAsync(() async {
        install = updater.downloadAndInstall();
        await pumpEventQueue();
      });
      await tester.pump();
      expect(find.text('Update waiting'), findsOneWidget);
      expect(find.text(syncing), findsOneWidget);
      expect(find.byKey(const ValueKey('update-later')), findsOneWidget);
      await tester.runAsync(() async {
        busy.set(null);
        await install;
      });
      await tester.pump();
      expect(find.text('Update not installed'), findsOneWidget);
    });
  });

  test('check failures: silent when automatic, shown when asked', () async {
    final updater = make();
    feed.checkError = const CloudFailure('offline');
    await updater.check();
    expect(updater.phase, UpdatePhase.idle);
    await updater.check(manual: true);
    expect(updater.phase, UpdatePhase.failed);
    expect(updater.message, contains('offline'));
    feed.ready = false;
    await updater.check(manual: true);
    expect(updater.message, contains('Pair this device'));
  });

  test('an installer failure discards the file and says so', () async {
    installer.outcome = InstallOutcome.failed;
    final updater = make();
    await updater.check();
    await updater.downloadAndInstall();
    expect(updater.phase, UpdatePhase.failed);
    expect(kept(), isEmpty);
  });

  test('start abandons install sessions an earlier process left', () async {
    final updater = make()..start();
    await pumpEventQueue();
    expect(installer.discarded, 1);
    updater.dispose();
  });

  group('a confirmation nobody answers', () {
    test('Cancel abandons the session; Install again works', () async {
      installer.confirmation = Completer();
      final updater = make();
      await updater.check();
      unawaited(updater.downloadAndInstall());
      await pumpEventQueue();
      expect(updater.phase, UpdatePhase.installing);
      expect(updater.busy, isTrue);
      await updater.cancelInstall();
      expect(installer.cancels, 1);
      expect(updater.phase, UpdatePhase.declined);
      expect(kept(), hasLength(1), reason: 'the verified file stays');
      // A late answer from the abandoned session changes nothing.
      await pumpEventQueue();
      expect(updater.phase, UpdatePhase.declined);
      installer.outcome = InstallOutcome.installed;
      await updater.installAgain();
      expect(installer.installs, hasLength(2));
      expect(updater.phase, UpdatePhase.idle);
    });

    test('back in the app, it times out; away from it, it waits', () async {
      installer.confirmation = Completer();
      final updater = make(installGrace: const Duration(milliseconds: 50));
      await updater.check();
      unawaited(updater.downloadAndInstall());
      await pumpEventQueue();
      // In front of the app (the app is not resumed): no timeout runs.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(updater.phase, UpdatePhase.installing);
      // Resumed, then the confirmation comes back in front: still waits.
      await updater.resumed();
      updater.left();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(updater.phase, UpdatePhase.installing);
      // Resumed and left there: the session is abandoned.
      await updater.resumed();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(installer.cancels, 1);
      expect(updater.phase, UpdatePhase.declined);
      expect(updater.busy, isFalse);
      await updater.check(manual: true);
      expect(updater.phase, UpdatePhase.available, reason: 'checks run again');
    });

    test('an answer clears the timeout', () async {
      installer.confirmation = Completer();
      final updater = make(installGrace: const Duration(milliseconds: 50));
      await updater.check();
      unawaited(updater.downloadAndInstall());
      await pumpEventQueue();
      await updater.resumed();
      installer.confirmation!.complete(
        const InstallResult(InstallOutcome.declined),
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(installer.cancels, 0);
      expect(updater.phase, UpdatePhase.declined);
    });
  });

  test('Cancel stops the download; a retry downloads again', () async {
    feed.hold = Completer();
    final updater = make();
    await updater.check();
    final first = updater.downloadAndInstall();
    await pumpEventQueue();
    expect(updater.phase, UpdatePhase.downloading);
    updater.cancelDownload();
    await first;
    expect(feed.cancels, 1);
    expect(updater.phase, UpdatePhase.available);
    expect(kept(), isEmpty);
    expect(installer.inspected, isEmpty);
    await updater.downloadAndInstall();
    expect(feed.downloads, 2);
    expect(installer.installs, hasLength(1));
  });

  test('not enough free space: nothing downloads, the need is shown', () async {
    installer.free = 7; // twice the 4-byte package is 8
    final updater = make();
    await updater.check();
    await updater.downloadAndInstall();
    expect(updater.phase, UpdatePhase.failed);
    expect(updater.message, contains('needs 8 bytes free'));
    expect(updater.message, contains('7 bytes is available'));
    expect(feed.downloads, 0);
    installer.free = 8;
    await updater.check(manual: true);
    await updater.downloadAndInstall();
    expect(feed.downloads, 1);
  });

  testWidgets('the panel shows version and size, then the reason', (
    tester,
  ) async {
    final updater = make();
    await tester.runAsync(updater.check);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdatePanel(updater: updater)),
      ),
    );
    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('Version 0.2.0 (4 bytes)'), findsOneWidget);
    installer.archive = facts(code: 2, signers: {otherKey});
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(find.text('Update discarded'), findsOneWidget);
    expect(find.textContaining('different key'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-panel')), findsNothing);
  });
}
