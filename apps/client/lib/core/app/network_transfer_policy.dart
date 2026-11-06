import '../ports/transfer_policy.dart';
import 'controller.dart';

/// The updater's download obeys the network setting like every other
/// transfer (spec #28 A4 and A7, decision #108 Q4, R3): under "Wi-Fi only"
/// (the Android default) it waits until the platform reports Wi-Fi or
/// Ethernet; under "Wi-Fi or mobile data", or where the platform has no
/// setting, it never waits. Checking for an update is not a transfer.
class NetworkSettingPolicy implements TransferPolicy {
  const NetworkSettingPolicy(this.controller);
  final ClientController controller;

  @override
  Future<String?> transferBlocked() async {
    final setting = controller.networkPolicy ?? controller.defaultNetworkPolicy;
    if (setting != 'wifi') return null;
    // An unknown network holds bytes, as for sync: nothing moves on mobile
    // data before the first report.
    return controller.onWifi == true ? null : 'Waiting for Wi-Fi';
  }
}
