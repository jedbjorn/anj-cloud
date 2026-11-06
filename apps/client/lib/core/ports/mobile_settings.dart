/// Port: device settings only a phone has (spec #28 A4).
///
/// Android: `AndroidBackground` (lib/platform/android/background.dart),
/// over the runner's `cloud.anj/background` channel. Linux has none.
library;

import 'package:flutter/foundation.dart';

abstract interface class MobileSettings implements Listenable {
  /// Whether the user allows notifications (POST_NOTIFICATIONS). When they
  /// do not, sync still runs and the in-app status stays truthful.
  bool get notificationsAllowed;

  /// Opens the system notification settings for this app.
  Future<void> openNotificationSettings();

  /// Connects to the runner before the controller starts; a background run
  /// that started the process is answered once [initialized] completes.
  Future<void> start(Future<void> initialized);
}
