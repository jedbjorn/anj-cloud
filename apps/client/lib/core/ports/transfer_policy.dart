/// Whether a transfer of file bytes may start now (spec #28 Background Sync,
/// decision #108 Q4 and R3): the network setting "Wi-Fi only" (the default)
/// or "Wi-Fi or mobile data" applies to every transfer, including the
/// updater's package download. Update checks are not transfers and run on
/// any network.
///
/// A4 (background sync and network) owns the setting and its Android
/// implementation; the updater only asks this hook before it downloads.
library;

abstract interface class TransferPolicy {
  /// Null when a transfer may start; otherwise the reason it waits, in the
  /// user's words (for example "Waiting for Wi-Fi").
  Future<String?> transferBlocked();
}

/// Allows every transfer: platforms without a network setting. Android
/// passes `NetworkSettingPolicy` (core/app/network_transfer_policy.dart).
class AnyNetworkPolicy implements TransferPolicy {
  const AnyNetworkPolicy();
  @override
  Future<String?> transferBlocked() async => null;
}
