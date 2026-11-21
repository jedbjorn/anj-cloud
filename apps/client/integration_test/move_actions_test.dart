import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import '../test/move_actions_test.dart' as shared;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  shared.moveActions(
    platforms: TargetPlatformVariant.only(TargetPlatform.android),
    native: true,
    captureScreen: (tester, name) async {
      await tester.runAsync(() async {
        final dir = await getApplicationSupportDirectory();
        final ack = File('${dir.path}/ack-$name');
        // The emulator layout runner captures this settled frame.
        // ignore: avoid_print
        print('ANJ-A6 SHOT $name');
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!ack.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (ack.existsSync()) ack.deleteSync();
      });
    },
  );
}
