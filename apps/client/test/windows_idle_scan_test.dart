@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';

import 'windows_idle_cpu.dart';

/// Idle CPU with the per-pass stat scan (no watcher) (see windows_idle_cpu.dart).
void main() {
  final seconds = idleSeconds();
  test(
    'idle CPU: stat-scan',
    () async {
      expect(
        await idleCpu('stat-scan', seconds!),
        greaterThanOrEqualTo(idleFiles),
      );
    },
    skip: seconds == null ? 'set ANJ_WW_IDLE_SECONDS' : null,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
