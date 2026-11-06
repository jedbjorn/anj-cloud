// On macOS, platformAdapters() and platformWatchers() agree (flag SC-045
// F3).
@TestOn('mac-os')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:anj_cloud/platform/adapters.dart';
import 'package:anj_cloud/platform/macos/macos_change_watchers.dart';
import 'package:anj_cloud/platform/macos/macos_platform_adapters.dart';
import 'package:anj_cloud/platform/watchers.dart';

void main() {
  test('both selectors pick macOS', () {
    expect(platformAdapters(), isA<MacosPlatformAdapters>());
    expect(platformWatchers(), isA<MacosChangeWatchers>());
  });
}
