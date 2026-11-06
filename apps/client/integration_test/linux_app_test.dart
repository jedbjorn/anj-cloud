import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/platform/linux/keyring_secrets.dart';
import 'package:anj_cloud/ui/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native keyring roundtrip and own synthetic root render', (
    tester,
  ) async {
    // Operator/runner checks that the existing collection is unlocked before
    // launching this test. This never unlocks or enumerates the keyring.
    final secrets = KeyringSecrets();
    final key = 'anj-cloud:qualification:${uniqueId()}';
    final value = uniqueId();
    try {
      await secrets.write(key, value);
      expect(await secrets.read(key), value);
    } finally {
      await secrets.delete(key);
    }
    final fixture = Directory.systemTemp.createTempSync('anj-app-integration-');
    final controller = ClientController(Directory('${fixture.path}/profile'));
    try {
      await tester.pumpWidget(CloudApp(controller: controller));
      await controller.initialize();
      final parent = Directory('${fixture.path}/files')..createSync();
      await controller.configureRoot(parent.path);
      final nested = File('${controller.root}/Documents/Nested/hello.txt');
      nested.parent.createSync();
      nested.writeAsStringSync('synthetic integration bytes');
      for (
        var i = 0;
        i < 100 &&
            !controller.entries.any(
              (e) => e['path'] == 'Documents/Nested/hello.txt',
            );
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      // Home deliberately starts collapsed. Prove the worker discovered the
      // real nested fixture before exercising the UI's folder controls.
      expect(
        controller.entries.any(
          (e) => e['path'] == 'Documents/Nested/hello.txt',
        ),
        isTrue,
      );
      expect(find.text('hello.txt'), findsNothing);
      await tester.tap(find.byTooltip('Expand Documents'));
      await tester.pumpAndSettle();
      expect(find.text('Nested'), findsOneWidget);
      expect(find.text('hello.txt'), findsNothing);
      await tester.tap(find.byTooltip('Expand Documents/Nested'));
      await tester.pumpAndSettle();
      expect(find.text('hello.txt'), findsOneWidget);
      expect(find.text('Pair device'), findsOneWidget);
    } finally {
      try {
        await controller.stop();
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        fixture.deleteSync(recursive: true);
      }
    }
  });
}
