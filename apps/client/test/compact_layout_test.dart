// Planner ruling on spec #31 (delta review I1): a short desktop window keeps
// the desktop layout on Linux, macOS and Windows; only Android switches to
// the phone layout when short (spec #28, #70). Narrow is compact everywhere.
import 'package:anj_cloud/ui/layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<bool> compactAt(
    WidgetTester tester,
    TargetPlatform platform,
    Size size,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    late bool compact;
    try {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              compact = compactLayout(context);
              return const SizedBox();
            },
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    return compact;
  }

  const short = Size(1470, 431); // a 13-inch MacBook's top half
  const narrow = Size(400, 900);
  const desktop = Size(1280, 720);

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}: a short window keeps the desktop layout', (
      tester,
    ) async {
      expect(await compactAt(tester, platform, short), isFalse);
      expect(await compactAt(tester, platform, desktop), isFalse);
      expect(await compactAt(tester, platform, narrow), isTrue);
    });
  }

  testWidgets('android: short (landscape) and narrow are the phone layout', (
    tester,
  ) async {
    expect(
      await compactAt(tester, TargetPlatform.android, const Size(900, 400)),
      isTrue,
    );
    expect(await compactAt(tester, TargetPlatform.android, narrow), isTrue);
    expect(await compactAt(tester, TargetPlatform.android, desktop), isFalse);
  });
}
