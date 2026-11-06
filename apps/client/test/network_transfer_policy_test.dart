import 'dart:io';

import 'package:anj_cloud/core/app/controller.dart';
import 'package:anj_cloud/core/app/network_transfer_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// The updater's package download obeys A4's network setting (spec #28 A4
/// and A7, decision #108 Q4, R3).
void main() {
  late Directory profile;
  setUp(() => profile = Directory.systemTemp.createTempSync('anj-net-policy-'));
  tearDown(() => profile.deleteSync(recursive: true));

  ClientController controller({String? defaultPolicy}) => ClientController(
    profile,
    secrets: MemorySecrets(),
    defaultNetworkPolicy: defaultPolicy,
  );

  test('Wi-Fi only: waits until Wi-Fi is reported, then downloads', () async {
    final c = controller(defaultPolicy: 'wifi');
    addTearDown(c.dispose);
    final policy = NetworkSettingPolicy(c);
    expect(await policy.transferBlocked(), 'Waiting for Wi-Fi');
    c.reportNetwork(wifi: false);
    expect(await policy.transferBlocked(), 'Waiting for Wi-Fi');
    c.reportNetwork(wifi: true);
    expect(await policy.transferBlocked(), isNull);
  });

  test('Wi-Fi or mobile data: never waits', () async {
    final c = controller(defaultPolicy: 'wifi')..networkPolicy = 'any';
    addTearDown(c.dispose);
    c.reportNetwork(wifi: false);
    expect(await NetworkSettingPolicy(c).transferBlocked(), isNull);
  });

  test('a platform without the setting never waits', () async {
    final c = controller();
    addTearDown(c.dispose);
    expect(await NetworkSettingPolicy(c).transferBlocked(), isNull);
  });
}
