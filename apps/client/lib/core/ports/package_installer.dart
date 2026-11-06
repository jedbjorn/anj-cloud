/// The platform's package installer (spec #28 A7): what the installed app
/// is, what a downloaded package is, and a user-approved install. Only
/// Android has one; desktop platforms update through their own installers
/// (doc #7) and have no implementation.
library;

/// An app package's identity: the installed app's or a downloaded archive's.
class PackageFacts {
  const PackageFacts({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.signers,
  });

  final String packageName;
  final int versionCode;
  final String versionName;

  /// SHA-256 of each signing certificate (DER), 64 lowercase hex characters.
  final Set<String> signers;

  static PackageFacts fromMap(Map<Object?, Object?> map) => PackageFacts(
    packageName: map['package'] as String,
    versionCode: (map['versionCode'] as num).toInt(),
    versionName: map['versionName'] as String? ?? '',
    signers: {
      for (final signer in map['signers'] as List? ?? const [])
        (signer as String).toLowerCase(),
    },
  );
}

enum InstallOutcome {
  /// The system installed the package (normally this process is replaced
  /// before the answer arrives).
  installed,

  /// The user declined or dismissed Android's confirmation.
  declined,

  /// The installer refused the package or the session failed.
  failed,
}

class InstallResult {
  const InstallResult(this.outcome, [this.message]);
  final InstallOutcome outcome;
  final String? message;
}

abstract interface class PackageInstallerPort {
  /// The running app's package.
  Future<PackageFacts> installed();

  /// A downloaded package's identity; null when it is not a readable
  /// package.
  Future<PackageFacts?> inspect(String path);

  /// Whether the user has allowed this app to install packages ("Install
  /// unknown apps").
  Future<bool> canRequestInstalls();

  /// Opens the system screen where the user allows it.
  Future<void> openInstallPermission();

  /// Free bytes on the filesystem holding [path]; null when unknown.
  Future<int?> freeBytes(String path);

  /// Abandons install sessions this app left behind (a process that ended
  /// mid-install). Run once at start.
  Future<void> discardSessions();

  /// Abandons the session waiting for the user's confirmation; its
  /// [install] answers [InstallOutcome.declined].
  Future<void> cancelInstall();

  /// Installs [path] through the system installer, which asks the user to
  /// confirm. The bytes handed to the installer are hashed as they are
  /// written and must equal [sha256] and [size], or nothing is committed.
  Future<InstallResult> install(
    String path, {
    required String sha256,
    required int size,
  });
}
