import '../gateway/dav_api.dart';
import '../sync/first_sync.dart';

/// How pairing behaves on one client beyond the shared code-only contract
/// (spec #35: server and pairing code; the code pins the household CA).
/// The desktop values keep the Linux client exactly as main has it; Android
/// passes its own (mobile_main.dart).
class PairingOptions {
  const PairingOptions({
    this.liveScan = false,
    this.firstSync,
    this.deviceLabel,
  });

  /// Desktop clients (Linux; macOS and Windows through the same shared UI):
  /// the first-sync screen after a first pairing with everything kept on
  /// the device until the user unticks it (decision #163).
  static const desktop = PairingOptions(firstSync: FirstSyncDefault.local);

  /// Offer the live camera scan of a QR code carrying the pairing code
  /// (#108 Q12).
  final bool liveScan;

  /// Show the first-sync folder screen at a first pairing, with this default
  /// (decision #118). Null: not wired on this client yet.
  final FirstSyncDefault? firstSync;

  /// The device label sent at enrolment; null uses the host name.
  final Future<String> Function()? deviceLabel;
}

/// The pairing code in a scanned QR code, normalized as typed entry is
/// (`normalizeInvitation`: a pinned spec #35 code or a legacy invitation),
/// or null when the QR code holds no pairing code. The QR code carries the
/// same text a person would type.
String? invitationFromQr(String text) {
  try {
    return normalizeInvitation(text.trim());
  } on FormatException {
    return null;
  }
}
