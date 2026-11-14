import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zxing2/qrcode.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/gateway/dav_api.dart';
import 'package:anj_cloud/core/app/pairing_inputs.dart';
import 'package:anj_cloud/core/app/qr_decode.dart';
import 'package:anj_cloud/core/sync/first_sync.dart';
import 'package:anj_cloud/ui/pairing_form.dart';
import 'package:anj_cloud/ui/app.dart';
import 'package:anj_cloud/core/ports/secret_store.dart';
import 'package:anj_cloud/ui/qr_scanner.dart' show QrScannerPage;

import 'fakes.dart';

const _invitation = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// A QR code of [text] as a camera's Y plane: dark modules 0x20, light 0xe0,
/// [scale] pixels per module, a 4-module quiet zone, rows padded to a stride.
LuminanceFrame qrFrame(String text, {int scale = 5, int padding = 24}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final side = (matrix.width + 8) * scale;
  final stride = side + padding;
  final bytes = Uint8List(stride * side)..fillRange(0, stride * side, 0xe0);
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) != 1) continue;
      for (var dy = 0; dy < scale; dy++) {
        final row = ((y + 4) * scale + dy) * stride;
        bytes.fillRange(row + (x + 4) * scale, row + (x + 5) * scale, 0x20);
      }
    }
  }
  return LuminanceFrame(bytes, side, side, stride);
}

void main() {
  late Directory fixture;
  setUpAll(() {
    fixture = Directory.systemTemp.createTempSync('anj-android-pairing-');
  });
  tearDownAll(() => fixture.deleteSync(recursive: true));

  group('QR decoding of a scanned pairing code', () {
    test('a camera frame with stride padding decodes to the invitation', () {
      final grouped = 'ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345-6789';
      final text = decodeQrFrame(qrFrame(grouped));
      expect(text, grouped);
      expect(invitationFromQr(text!), 'ABCDEFGHJKMNPQRSTVWXYZ0123456789');
    });

    test('a QR code of a pinned spec #35 code gives the code as typed', () {
      // 28 characters (decision #153: 136 bits, so the first character
      // carries one), grouped as the admin shows it.
      const pinned = '0BCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345';
      final text = decodeQrFrame(qrFrame(pinned));
      expect(text, pinned);
      final code = invitationFromQr(text!)!;
      expect(code, '0BCDEFGHJKMNPQRSTVWXYZ012345');
      expect(code.length, pinnedInvitationLength);
      expect(invitationCaPin(code), isNotNull);
    });

    test('a frame without a QR code, or a malformed frame, is null', () {
      final blank = Uint8List(320 * 240)..fillRange(0, 320 * 240, 0x80);
      expect(decodeQrFrame(LuminanceFrame(blank, 320, 240, 320)), isNull);
      expect(decodeQrFrame(LuminanceFrame(blank, 320, 240, 100)), isNull);
      expect(decodeQrFrame(LuminanceFrame(blank, 320, 480, 320)), isNull);
    });

    test('a QR code that is not an invitation is refused', () {
      final text = decodeQrFrame(qrFrame('https://example.invalid/'));
      expect(text, 'https://example.invalid/');
      expect(invitationFromQr(text!), isNull);
      expect(invitationFromQr('${_invitation}0'), isNull);
    });
  });

  group('pairing form', () {
    Future<ClientController> open(
      WidgetTester tester,
      PairingOptions options,
      Size size,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ClientController(
        Directory('/unused-a3-profile'),
        secrets: MemorySecrets(),
        pairingOptions: options,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPairing(context, controller),
                child: const Text('Pair device'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pair device'));
      await tester.pumpAndSettle();
      return controller;
    }

    const android = PairingOptions(
      liveScan: true,
      firstSync: FirstSyncDefault.cloud,
    );

    testWidgets(
      'phone: a page with the household server, the code and Scan; no CA, '
      'no fingerprint, no Check approval',
      (tester) async {
        final controller = await open(tester, android, const Size(360, 800));
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.widgetWithText(AppBar, 'Pair this device'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final server = tester.widget<TextField>(
          find.byKey(const ValueKey('pair-server')),
        );
        expect(server.controller!.text, ClientController.householdOrigin);
        expect(find.byKey(const ValueKey('pair-code')), findsOneWidget);
        expect(find.byKey(const ValueKey('pair-scan')), findsOneWidget);
        expect(find.textContaining('CA'), findsNothing);
        expect(find.text('Check approval'), findsNothing);
        expect(find.text('Device fingerprint (SHA-256)'), findsNothing);
        final request = tester.widget<FilledButton>(
          find.byKey(const ValueKey('pair-request')),
        );
        expect(request.onPressed, isNotNull);
        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();
        controller.dispose();
      },
    );

    testWidgets(
      'a refused code keeps its reason on the form, not the worker line',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = ClientController(
          Directory('/unused-a3-profile'),
          secrets: MemorySecrets(),
          pairingOptions: android,
        )..pairingMessage = notThisServer;
        controller.message = 'Sync paused.';
        await tester.pumpWidget(
          MaterialApp(home: PairingForm(controller: controller, page: true)),
        );
        await tester.pumpAndSettle();
        expect(find.text(notThisServer), findsOneWidget);
        expect(find.text('Sync paused.'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );

    testWidgets('phone: the pairing page shows the full key notice', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ClientController(
        Directory('/unused-a3-profile'),
        secrets: _ResettableSecrets(),
        pairingOptions: android,
      )..keyUnavailable = true;
      await tester.pumpWidget(
        MaterialApp(home: PairingForm(controller: controller, page: true)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('pair again with a new pairing code'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('key-reset')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('desktop: the spec #35 dialog, no Scan', (tester) async {
      final controller = await open(
        tester,
        PairingOptions.desktop,
        const Size(1280, 900),
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      final server = tester.widget<TextField>(
        find.byKey(const ValueKey('pair-server')),
      );
      expect(server.controller!.text, ClientController.householdOrigin);
      expect(find.byKey(const ValueKey('pair-scan')), findsNothing);
      expect(find.text('Pairing code'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      controller.dispose();
    });

    testWidgets(
      'a legacy invitation waiting for the admin shows the device fingerprint',
      (tester) async {
        final controller = await open(
          tester,
          PairingOptions.desktop,
          const Size(1280, 900),
        );
        controller
          ..fingerprint = 'ab' * 32
          ..awaitingFingerprintApproval = true;
        // The form reads the controller when it opens.
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pair device'));
        await tester.pumpAndSettle();
        expect(find.text('Device fingerprint (SHA-256)'), findsOneWidget);
        expect(find.text('ab' * 32), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        controller.dispose();
      },
    );
  });

  group('live scan page', () {
    Future<void> scan(
      WidgetTester tester,
      Future<List<CameraDescription>> Function() cameras,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: QrScannerPage(cameras: cameras)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('declined camera permission: typed entry remains', (
      tester,
    ) async {
      await scan(
        tester,
        () async => throw CameraException('CameraAccessDenied', 'denied'),
      );
      expect(
        find.textContaining('Camera permission was declined'),
        findsOneWidget,
      );
      expect(find.text('Back to pairing'), findsOneWidget);
    });

    testWidgets('no camera on the device', (tester) async {
      await scan(tester, () async => const []);
      expect(find.textContaining('no camera'), findsOneWidget);
    });

    testWidgets('leaving after a refusal returns no invitation', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? result = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => QrScannerPage(
                        cameras: () async =>
                            throw CameraException('CameraAccessDenied', null),
                      ),
                    ),
                  ),
              child: const Text('Scan'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back to pairing'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  testWidgets(
    'unreadable key: the home screen offers the reset in plain words',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final secrets = _ResettableSecrets();
      final profile = Directory('${fixture.path}/notice-profile')
        ..createSync(recursive: true);
      final controller = ClientController(
        profile,
        secrets: secrets,
        pairingOptions: const PairingOptions(liveScan: true),
      )..keyUnavailable = true;
      await tester.pumpWidget(CloudApp(controller: controller));
      expect(find.text("This device's key is unavailable"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('key-reset')));
      await tester.pumpAndSettle();
      expect(find.text("Reset this device's pairing?"), findsOneWidget);
      expect(
        find.textContaining('pair again with a new pairing code'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('key-reset-confirm')));
        await tester.pump();
        for (var i = 0; i < 50 && secrets.resets == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(secrets.resets, 1);
      expect(find.text("This device's key is unavailable"), findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('no reset route (Linux keyring): no reset offered', (
    tester,
  ) async {
    final controller = ClientController(
      Directory('/unused-a3-profile'),
      secrets: MemorySecrets(),
    )..keyUnavailable = true;
    await tester.pumpWidget(CloudApp(controller: controller));
    expect(find.byKey(const ValueKey('key-unavailable')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'an unreadable key on the first-sync screen offers the reset (F2)',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final profile = Directory('${fixture.path}/first-sync-key-profile')
        ..createSync(recursive: true);
      final controller =
          ClientController(
              profile,
              secrets: _BrokenResettableSecrets(),
              pairingOptions: const PairingOptions(
                liveScan: true,
                firstSync: FirstSyncDefault.cloud,
              ),
            )
            ..firstSyncPending = true
            ..keyUnavailable = true;
      await tester.pumpWidget(CloudApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('Choose what stays on this device'), findsOneWidget);
      expect(find.text("This device's key is unavailable"), findsOneWidget);
      expect(find.byKey(const ValueKey('key-reset')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  test(
    'the app manifest asks for CAMERA only and removes the plugin extras',
    () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      final permission = RegExp(
        r'<uses-permission\s+android:name="([^"]+)"(\s+tools:node="remove")?',
      );
      final kept = <String>{};
      final removed = <String>{};
      for (final match in permission.allMatches(manifest)) {
        (match.group(2) == null ? kept : removed).add(match.group(1)!);
      }
      expect(kept, {
        'android.permission.INTERNET',
        'android.permission.CAMERA',
        // Background sync and its network setting and notifications (A4).
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.RECEIVE_BOOT_COMPLETED',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
        'android.permission.POST_NOTIFICATIONS',
        // The in-app updater's PackageInstaller session (A7).
        'android.permission.REQUEST_INSTALL_PACKAGES',
        // Phone folders: All files access (spec #52).
        'android.permission.MANAGE_EXTERNAL_STORAGE',
      });
      expect(removed, {
        'android.permission.RECORD_AUDIO',
        'android.permission.WRITE_EXTERNAL_STORAGE',
        'android.permission.READ_EXTERNAL_STORAGE',
      });
    },
  );
}

/// Secure storage that cannot start (every read fails) but can be reset.
class _BrokenResettableSecrets extends MemorySecrets
    implements SecretStoreReset {
  @override
  Future<String?> read(String key) async =>
      throw PlatformException(code: 'Exception encountered');
  @override
  Future<void> resetAll() async {}
}

class _ResettableSecrets extends MemorySecrets implements SecretStoreReset {
  int resets = 0;
  @override
  Future<void> resetAll() async => resets++;
}
