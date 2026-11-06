import '../app/controller.dart';

/// What an install must not interrupt (spec #37 rule 4): files moving to or
/// from the server, or a Finish editing still to complete. Null when none.
/// Shared by the desktop updater and the Android updater (spec #28 A7):
/// installing restarts the app, which would cut an upload short.
String? controllerUpdateBlocker(ClientController controller) {
  // Also while paused: a transfer still winding down counts (review L2).
  if (controller.transferring.isNotEmpty) return 'files finish syncing';
  if (controller.finishingEdits) return 'Finish editing completes';
  return null;
}

/// The status text while an install waits for [controllerUpdateBlocker].
String updateStartsWhen(String version, String? waitingFor) =>
    'Update (version $version) starts when ${waitingFor ?? 'sync is idle'}…';
