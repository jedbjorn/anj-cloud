// Spec #37 U-linux: the desktop updater's state machine with a fake feed and
// a fake manager port; manifests are signed with a throwaway Ed25519 key by
// the OpenSSL CLI (test fixture only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/core/ports/self_update.dart';
import 'package:anj_cloud/core/state/model.dart';
import 'package:anj_cloud/core/update/desktop_updater.dart';
import 'package:anj_cloud/core/update/release.dart';
import 'package:anj_cloud/ui/update_notice.dart';

import 'test_platform.dart';

class FakeFeed extends ChangeNotifier implements UpdateFeed {
  @override
  bool ready = true;
  ReleaseManifest? served;
  Object? checkError;
  Object? downloadError;
  int downloads = 0;

  /// When set, the next answer waits for it (a check in flight).
  Completer<void>? gate;
  @override
  Future<ReleaseManifest?> latest(String target) async {
    final waiting = gate;
    if (waiting != null) await waiting.future;
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
    if (downloadError != null) throw downloadError!;
    await destination.writeAsBytes(
      utf8.encode('package ${manifest.versionCode}'),
    );
  }
}

class FakePort implements SelfUpdatePort {
  InstalledBuild? build = const InstalledBuild(
    target: linuxReleaseTarget,
    version: '2026.11.05.10',
    versionCode: 10,
  );
  SelfUpdateFailure? checkFailure;
  SelfUpdateFailure? handOverFailure;
  final calls = <String>[];
  @override
  Future<InstalledBuild?> installed() async => build;
  @override
  Future<void> prepare(Directory directory) async => calls.add('prepare');
  @override
  Future<void> check(File archive, File manifest) async {
    calls.add('check ${archive.existsSync()} ${manifest.existsSync()}');
    if (checkFailure != null) throw checkFailure!;
  }

  @override
  Future<void> handOver(File archive, File manifest, File result) async {
    calls.add('handOver ${archive.path.split('/').last}');
    if (handOverFailure != null) throw handOverFailure!;
  }
}

void main() {
  if (skipSuite('Desktop updater with OpenSSL-signed manifests', opensslSkip)) {
    return;
  }
  late Directory fixture;
  late File privateKey;
  late String keyText;

  setUpAll(() async {
    fixture = Directory.systemTemp.createTempSync('anj-updater-');
    privateKey = File('${fixture.path}/release.pem');
    final made = await Process.run(testOpenssl!, [
      'genpkey',
      '-algorithm',
      'ed25519',
      '-out',
      privateKey.path,
    ]);
    expect(made.exitCode, 0);
    final der = await Process.run(testOpenssl!, [
      'pkey',
      '-in',
      privateKey.path,
      '-pubout',
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    final raw = (der.stdout as List<int>).sublist(12);
    keyText = '# test\ned25519 ${base64.encode(raw)}\n';
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  ReleaseKey key() => ReleaseKey.parse(keyText)!;

  Future<ReleaseManifest> signed(int code, {int? floor, String? keyId}) async {
    final unsigned = ReleaseManifest(
      target: linuxReleaseTarget,
      version: '2026.11.05.$code',
      versionCode: code,
      size: 9,
      sha256: sha256.convert([code]).toString(),
      keyId: keyId ?? key().id,
      signature: '${'A' * 86}==',
    );
    final message = File('${fixture.path}/message')
      ..writeAsBytesSync(unsigned.signedMessage);
    final signature = File('${fixture.path}/signature');
    final done = await Process.run(testOpenssl!, [
      'pkeyutl',
      '-sign',
      '-inkey',
      privateKey.path,
      '-rawin',
      '-in',
      message.path,
      '-out',
      signature.path,
    ]);
    expect(done.exitCode, 0);
    return ReleaseManifest.fromJson({
      ...unsigned.toJson(),
      'signature': base64.encode(signature.readAsBytesSync()),
      'min_client_version_code': ?floor,
    }, linuxReleaseTarget);
  }

  late FakeFeed feed;
  late FakePort port;
  late Directory updates;
  late List<String> events;
  String? blocking;
  late ValueNotifier<int> busy;

  DesktopUpdater updater({String? key}) => DesktopUpdater(
    feed: feed,
    port: port,
    directory: updates,
    loadKey: () async => key ?? keyText,
    quit: () async => events.add('quit'),
    blocker: () => blocking,
    busySignal: busy,
  );

  setUp(() {
    feed = FakeFeed();
    port = FakePort();
    updates = Directory(
      '${fixture.path}/profile-${DateTime.now().microsecondsSinceEpoch}/updates',
    );
    events = [];
    blocking = null;
    busy = ValueNotifier(0);
  });

  // Real (if short) waits, not only event-loop turns: the download and the
  // manager check write files, which take wall-clock time on APFS
  // (mac-test) where a few zero-delay turns were enough on the VM host.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<String> staged() => updates.existsSync()
      ? (updates.listSync().map((e) => e.path.split('/').last).toList()..sort())
      : [];

  test('a build without a receipt or a release key never checks', () async {
    port.build = null;
    final noReceipt = updater();
    await noReceipt.start();
    expect(noReceipt.phase, DesktopUpdatePhase.off);
    port.build = FakePort().build;
    final noKey = updater(key: '# no key yet\n');
    await noKey.start();
    await settle();
    expect(noKey.enabled, isFalse);
    expect(feed.downloads, 0);
  });

  test('start: a newer signed release downloads, is checked by the manager '
      'and offered once', () async {
    feed.served = await signed(11);
    final update = updater();
    await update.start();
    await settle();
    expect(update.phase, DesktopUpdatePhase.ready);
    expect(update.notice, 'Update available (version 2026.11.05.11)');
    expect(update.status, isNull);
    expect(port.calls, ['prepare', 'check true true']);
    expect(staged(), ['11.json', '11.tar.gz']);
    expect(
      ReleaseManifest.fromJson(
        jsonDecode(File('${updates.path}/11.json').readAsStringSync()),
        linuxReleaseTarget,
      ),
      feed.served,
    );
    // The same release again: nothing new is downloaded.
    await update.check();
    expect(feed.downloads, 1);
  });

  test(
    'a bad signature, another key or a downgrade is never downloaded',
    () async {
      final good = await signed(11);
      final cases = {
        'signature': ReleaseManifest.fromJson({
          ...good.toJson(),
          'version_code': 12,
        }, linuxReleaseTarget),
        'key': await signed(11, keyId: '0123456789abcdef'),
      };
      for (final MapEntry(key: name, value: manifest) in cases.entries) {
        feed = FakeFeed()..served = manifest;
        final update = updater();
        await update.start();
        await settle();
        expect(update.phase, DesktopUpdatePhase.idle, reason: name);
        expect(update.status, DesktopUpdater.verifyFailed, reason: name);
        expect(update.detail, isNotEmpty);
        expect(update.notice, isNull);
        expect(feed.downloads, 0, reason: name);
        expect(staged(), isEmpty);
      }
      feed = FakeFeed()..served = await signed(10);
      final same = updater();
      await same.start();
      await settle();
      expect(
        (same.phase, same.status, feed.downloads),
        (DesktopUpdatePhase.idle, null, 0),
      );
    },
  );

  test(
    'a download or manager check that fails verification is discarded',
    () async {
      feed.served = await signed(11);
      feed.downloadError = const ReleaseRefused('checksum differs');
      final refused = updater();
      await refused.start();
      await settle();
      expect(
        (refused.status, refused.detail),
        (DesktopUpdater.verifyFailed, 'checksum differs'),
      );
      expect(staged(), isEmpty);

      feed.downloadError = null;
      port.checkFailure = const SelfUpdateFailure(
        "The update's receipt does not match its signed version.",
      );
      final manager = updater();
      await manager.start();
      await settle();
      expect(manager.status, DesktopUpdater.verifyFailed);
      expect(manager.phase, DesktopUpdatePhase.idle);
      expect(staged(), isEmpty);
    },
  );

  test('an unreachable server or a cut-off download stays silent', () async {
    feed.checkError = const CloudFailure('offline');
    final offline = updater();
    await offline.start();
    await settle();
    expect((offline.phase, offline.status), (DesktopUpdatePhase.idle, null));
    feed
      ..checkError = null
      ..served = await signed(11)
      ..downloadError = const CloudFailure('The download was cut off.');
    await offline.check();
    expect((offline.phase, offline.status), (DesktopUpdatePhase.idle, null));
    expect(staged(), isEmpty);
    feed.downloadError = null;
    await offline.check();
    expect(offline.phase, DesktopUpdatePhase.ready);
  });

  test('Later hides the notice until the next scheduled check', () async {
    feed.served = await signed(11);
    final update = updater();
    await update.start();
    await settle();
    update.later();
    expect(update.notice, isNull);
    await update.check();
    expect(update.notice, isNull);
    await update.check(scheduled: true);
    expect(update.notice, 'Update available (version 2026.11.05.11)');
    expect(feed.downloads, 1);
  });

  test(
    'Update now waits for syncing and Finish editing, hands over, then quits',
    () async {
      feed.served = await signed(11);
      final update = updater();
      await update.start();
      await settle();
      blocking = 'files finish syncing';
      final done = update.updateNow();
      await settle();
      expect(update.phase, DesktopUpdatePhase.waiting);
      expect(update.notice, contains('starts when files finish syncing'));
      expect(port.calls.where((c) => c.startsWith('handOver')), isEmpty);
      blocking = 'Finish editing completes';
      busy.value++;
      await settle();
      expect(update.phase, DesktopUpdatePhase.waiting);
      blocking = null;
      busy.value++;
      await done;
      expect(port.calls.last, 'handOver 11.tar.gz');
      expect(events, ['quit']);
      expect(update.phase, DesktopUpdatePhase.installing);
    },
  );

  test('a check in flight at Update now never touches the handed-over files '
      '(review M2)', () async {
    feed.served = await signed(11);
    final update = updater();
    await update.start();
    await settle();
    // Installing: the answer (a newer release, even) arrives after the hand-over.
    feed.gate = Completer<void>();
    final inFlight = update.check(scheduled: true);
    await settle();
    await update.updateNow();
    expect(port.calls.last, 'handOver 11.tar.gz');
    feed.served = await signed(12);
    feed.gate!.complete();
    await inFlight;
    expect(update.phase, DesktopUpdatePhase.installing);
    expect(feed.downloads, 1);
    expect(staged(), ['11.json', '11.tar.gz']);
    expect(port.calls.where((c) => c == 'prepare'), hasLength(1));

    // Waiting for sync: the answer arrives while Update now waits.
    feed = FakeFeed()..served = await signed(11);
    updates = Directory('${updates.path}-waiting');
    events.clear();
    port.calls.clear();
    final waiting = updater();
    await waiting.start();
    await settle();
    feed.gate = Completer<void>();
    final pending = waiting.check(scheduled: true);
    await settle();
    blocking = 'files finish syncing';
    final done = waiting.updateNow();
    await settle();
    feed.served = await signed(12);
    feed.gate!.complete();
    await pending;
    expect(waiting.phase, DesktopUpdatePhase.waiting);
    expect(feed.downloads, 1);
    expect(staged(), ['11.json', '11.tar.gz']);
    blocking = null;
    busy.value++;
    await done;
    expect(port.calls.last, 'handOver 11.tar.gz');
    expect(events, ['quit']);
  });

  test(
    'Cancel while waiting returns to the offer; a hand-over failure is shown',
    () async {
      feed.served = await signed(11);
      final update = updater();
      await update.start();
      await settle();
      blocking = 'files finish syncing';
      final done = update.updateNow();
      await settle();
      update.cancelWaiting();
      await done;
      expect(update.phase, DesktopUpdatePhase.ready);
      expect(events, isEmpty);
      blocking = null;
      port.handOverFailure = const SelfUpdateFailure('no manager');
      await update.updateNow();
      expect(
        (update.phase, update.status, update.detail),
        (DesktopUpdatePhase.ready, DesktopUpdater.installFailed, 'no manager'),
      );
      expect(events, isEmpty);
    },
  );

  test("the manager's outcome is read once at the next start", () async {
    updates.createSync(recursive: true);
    File('${updates.path}/result.json').writeAsStringSync(
      jsonEncode({'ok': true, 'version': '2026.11.05.11', 'version_code': 11}),
    );
    File('${updates.path}/11.tar.gz').writeAsStringSync('stale');
    final ok = updater();
    await ok.start();
    expect(ok.status, 'Updated to version 2026.11.05.11');
    expect(staged(), isEmpty);
    File('${updates.path}/result.json').writeAsStringSync(
      jsonEncode({'ok': false, 'message': 'AnJ Cloud did not quit in time'}),
    );
    final failed = updater();
    await failed.start();
    expect(
      (failed.status, failed.detail),
      (DesktopUpdater.installFailed, 'AnJ Cloud did not quit in time'),
    );
    failed.dismissStatus();
    expect(failed.status, isNull);
  });

  test('a minimum version above this one shows Update required', () async {
    feed.served = await signed(11, floor: 11);
    final update = updater();
    await update.start();
    await settle();
    expect(update.notice, 'Update required (version 2026.11.05.11)');
    feed.downloadError = const CloudFailure('offline');
    final waiting = updater();
    await waiting.start();
    await settle();
    expect((waiting.notice, waiting.status), (null, 'Update required'));
  });

  testWidgets('the notice offers Update now and Later', (tester) async {
    late DesktopUpdater update;
    await tester.runAsync(() async {
      feed.served = await signed(11);
      update = updater();
      await update.start();
      await settle();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: update,
            builder: (context, _) => UpdateNotice(updater: update),
          ),
        ),
      ),
    );
    expect(
      find.text('Update available (version 2026.11.05.11)'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-notice')), findsNothing);
    await tester.runAsync(() => update.check(scheduled: true));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('update-now')));
      await settle();
    });
    await tester.pump();
    expect(events, ['quit']);
    expect(find.textContaining('AnJ Cloud restarts by itself'), findsOneWidget);
  });
}
