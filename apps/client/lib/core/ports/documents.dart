/// Ports for a platform documents provider and its app allowlist (spec #28
/// A5, decision #127). Android implements them (`lib/platform/android/`):
/// the "AnJ Cloud" DocumentsProvider and the "Apps with access" settings.
/// Linux has neither and returns null from `PlatformAdapters.startDocuments`.
library;

import 'package:flutter/foundation.dart';

import 'documents_filesystem.dart';

export 'documents_filesystem.dart';

/// What a documents provider needs from the running client: the engine's
/// current library projection and one command channel to the sync worker.
/// [ClientController] implements it; listeners hear every projection change.
abstract interface class DocumentsHost implements Listenable {
  /// The last library projection the worker sent (one map per entry).
  List<Map<String, dynamic>> get entries;

  /// Whether the worker runs with its root and storage ready.
  bool get documentsReady;

  /// Set by the documents provider: called after the app itself renamed
  /// or moved an item, so ids and approvals follow it.
  void Function(String from, String to)? onLocalRename;

  /// One documents command to the worker (`open`, `create`, `rename`,
  /// `move`, `delete`, `closed`); completes with the worker's answer or
  /// fails with a [DocumentsFailure].
  Future<Map<String, Object?>> documentsCommand(
    String op,
    Map<String, Object?> args,
  );
}

enum AccessMode { read, write }

/// An app on the phone the user can approve (launchable apps, decision #127).
class InstalledApp {
  const InstalledApp(this.package, this.label, {this.icon});
  final String package;
  final String label;

  /// A small PNG, when the platform supplies one.
  final Uint8List? icon;
}

/// The live status of one approval: approved but not used yet, used through
/// a folder the app added (connected), or revoked by the user.
enum ApprovalStatus { approved, connected, revoked }

/// One approval: [package] may reach [folder] (root-relative, '' for all of
/// AnJ Cloud) and everything beneath it, read-only or read-write.
class AppApproval {
  const AppApproval({
    required this.package,
    required this.folder,
    required this.mode,
    required this.status,
    required this.approvedAt,
    this.lastSeen,
    this.revokedAt,
    this.openFiles = 0,
  });
  final String package;
  final String folder;
  final AccessMode mode;
  final ApprovalStatus status;
  final DateTime approvedAt;
  final DateTime? lastSeen;
  final DateTime? revokedAt;

  /// Descriptors this app still holds in [folder]; a revoke stops new calls,
  /// not a descriptor already handed out (A1 R2).
  final int openFiles;
}

/// An app that tried to reach [folder] and was refused (not approved).
class AccessRequest {
  const AccessRequest(this.package, this.folder, this.at);
  final String package;
  final String folder;
  final DateTime at;
}

/// A single file other apps keep a persisted grant on (spec #28 R1): an app
/// asked the system picker for one file and kept the permission. It reaches
/// that one document only, but until the user revokes it here.
class FileGrant {
  const FileGrant({
    required this.documentId,
    required this.name,
    required this.holders,
    required this.write,
    this.packages = const [],
  });

  /// The provider's document id.
  final String documentId;

  /// Root-relative path, or a description when the file is gone.
  final String name;

  /// How many persisted grants the platform reports (one per app).
  final int holders;

  /// Whether any of them allows writing.
  final bool write;

  /// Apps seen using the file through its grant (the platform's list does
  /// not name them); may be fewer than [holders].
  final List<String> packages;
}

/// "Apps with access" (decision #127): the allowlist the provider enforces.
abstract interface class AppAccess implements Listenable {
  /// The phone's launchable apps, without this one.
  Future<List<InstalledApp>> installedApps();

  /// Labels (and icons) for packages, including ones not in the launcher.
  Future<Map<String, InstalledApp>> describe(Iterable<String> packages);

  List<AppApproval> get approvals;
  List<AccessRequest> get requests;

  /// Folders (root-relative directory paths) that can be approved now.
  List<String> get folders;

  Future<void> approve(String package, String folder, AccessMode mode);

  /// Ends [package]'s access to [folder]: the provider refuses its next
  /// call, and the platform grants the app holds there are withdrawn.
  Future<void> revoke(String package, String folder);

  /// Removes a revoked row (or a request) from the list.
  Future<void> forget(String package, String folder);

  /// Opens [package] so the user can add the folder in its picker.
  Future<bool> openApp(String package);

  /// Single files apps keep persisted grants on (R1), from the platform.
  Future<List<FileGrant>> fileGrants();

  /// Withdraws every app's grant on that one file.
  Future<void> revokeFile(String documentId);
}
