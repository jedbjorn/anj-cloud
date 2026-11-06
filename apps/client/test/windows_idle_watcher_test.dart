@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';

import 'windows_idle_cpu.dart';

/// Idle CPU with the ReadDirectoryChangesW watcher (see windows_idle_cpu.dart).
void main() {
  final seconds = idleSeconds();
  test(
    'idle CPU: watcher',
    () async {
      expect(
        await idleCpu('watcher', seconds!),
        greaterThanOrEqualTo(idleFiles),
      );
    },
    skip: seconds == null ? 'set ANJ_WW_IDLE_SECONDS' : null,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
