import 'package:path/path.dart' as p;

import 'cloud_api.dart';
import '../state/model.dart';
import '../local/root_tree.dart';

/// Directory sharing between household users (spec #26). Shared Dart: the
/// gateway API types, the client-side scope rules and the row wording.

/// A recipient's permission: "Can edit" (Nextcloud 15) or "View only" (1).
enum SharePermission {
  edit('Can edit'),
  view('View only');

  const SharePermission(this.label);
  final String label;

  static SharePermission parse(Object? value) => switch (value) {
    'edit' => SharePermission.edit,
    'view' => SharePermission.view,
    _ => throw const CloudFailure('Invalid sharing response.'),
  };
}

/// An enabled household user other than this account (`GET /v1/household/users`).
class HouseholdUser {
  const HouseholdUser(this.id, this.displayName);
  final String id;
  final String displayName;

  static HouseholdUser fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['display_name'] is! String) {
      throw const CloudFailure('Invalid household list.');
    }
    return HouseholdUser(json['id'] as String, json['display_name'] as String);
  }
}

/// A share of one of this account's folders (`GET /v1/shares/outgoing`).
class OutgoingShare {
  const OutgoingShare(
    this.shareId,
    this.path,
    this.recipientId,
    this.recipientName,
    this.permission,
  );
  final String shareId;
  final String path;
  final String recipientId;
  final String recipientName;
  final SharePermission permission;

  static OutgoingShare fromJson(Object? json) {
    if (json is! Map ||
        json['share_id'] is! String ||
        json['path'] is! String ||
        json['recipient_id'] is! String ||
        json['recipient_display_name'] is! String) {
      throw const CloudFailure('Invalid sharing response.');
    }
    return OutgoingShare(
      json['share_id'] as String,
      json['path'] as String,
      json['recipient_id'] as String,
      json['recipient_display_name'] as String,
      SharePermission.parse(json['permission']),
    );
  }
}

/// A share another household user made to this account, mounted at [path]:
/// `Shared/<folder>`, or `<Documents|Music|Videos>/<folder>` for a share
/// from the owner's same folder (spec #34 P6). [ownerUnavailable]: the owner's account is disabled,
/// so Nextcloud hides the folder; it is paused here, never treated as deleted.
class IncomingShare {
  const IncomingShare(
    this.shareId,
    this.path,
    this.ownerName,
    this.permission, {
    this.ownerUnavailable = false,
  });
  final String shareId;
  final String path;
  final String ownerName;
  final SharePermission permission;
  final bool ownerUnavailable;

  static IncomingShare fromJson(Object? json) {
    if (json is! Map ||
        json['share_id'] is! String ||
        json['path'] is! String ||
        json['owner_display_name'] is! String) {
      throw const CloudFailure('Invalid sharing response.');
    }
    final path = json['path'] as String;
    validateRelative(path);
    if (!isMountPlace(path)) {
      throw const CloudFailure('Incoming share outside its allowed places.');
    }
    return IncomingShare(
      json['share_id'] as String,
      path,
      json['owner_display_name'] as String,
      SharePermission.parse(json['permission']),
      ownerUnavailable: json['owner_unavailable'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'share_id': shareId,
    'path': path,
    'owner_display_name': ownerName,
    'permission': permission.name,
    'owner_unavailable': ownerUnavailable,
  };
}

/// The gateway's sharing routes. Optional: a cloud without them (or an
/// unpaired one) is simply not a [SharingApi]. Every call is a network
/// request, so the pause gate refuses all of them (#53).
abstract interface class SharingApi {
  /// Null when the gateway has no sharing routes (an older gateway).
  Future<List<IncomingShare>?> incomingShares();
  Future<List<OutgoingShare>> outgoingShares();
  Future<List<HouseholdUser>> householdUsers();
  Future<OutgoingShare> createShare(
    String path,
    String recipientId,
    SharePermission permission,
  );
  Future<OutgoingShare> updateShare(String shareId, SharePermission permission);
  Future<void> removeShare(String shareId);

  /// Leaves a share made to this account (decision #157): reached when the
  /// shared folder is deleted on this device; the share ends for this
  /// account only and the owner's folder is untouched.
  Future<void> leaveShare(String shareId);

  /// Renames a folder shared with this account for everyone (decision
  /// #155); returns this account's mount path afterwards. A name the owner
  /// already has there is refused (409).
  Future<String?> renameForEveryone(String shareId, String name);
}

/// Forwards [SharingApi] through a wrapping cloud (renewal, pause gate,
/// activity). [beforeSharing] runs before every call: the pause gate refuses
/// there, before any request is made.
mixin ForwardSharing implements SharingApi {
  CloudApi get sharingTarget;
  void beforeSharing() {}

  SharingApi get _target {
    beforeSharing();
    final target = sharingTarget;
    if (target is SharingApi) return target as SharingApi;
    throw const CloudFailure('Sharing is not available on this connection.');
  }

  @override
  Future<List<IncomingShare>?> incomingShares() async {
    beforeSharing();
    final target = sharingTarget;
    return target is SharingApi
        ? (target as SharingApi).incomingShares()
        : null;
  }

  @override
  Future<List<OutgoingShare>> outgoingShares() async =>
      _target.outgoingShares();
  @override
  Future<List<HouseholdUser>> householdUsers() async =>
      _target.householdUsers();
  @override
  Future<OutgoingShare> createShare(
    String path,
    String recipientId,
    SharePermission permission,
  ) async => _target.createShare(path, recipientId, permission);
  @override
  Future<OutgoingShare> updateShare(
    String shareId,
    SharePermission permission,
  ) async => _target.updateShare(shareId, permission);
  @override
  Future<void> removeShare(String shareId) async =>
      _target.removeShare(shareId);
  @override
  Future<void> leaveShare(String shareId) async => _target.leaveShare(shareId);
  @override
  Future<String?> renameForEveryone(String shareId, String name) async =>
      _target.renameForEveryone(shareId, name);
}

/// The folder Nextcloud mounts incoming shares in (decision #78 N1).
const sharedFolder = 'Shared';

/// A direct child of `Shared/`: where an incoming share is mounted.
bool isIncomingMount(String path) =>
    p.posix.dirname(path) == sharedFolder && path != sharedFolder;

/// The top folders whose shares arrive in the recipient's same folder
/// instead of `Shared/` (spec #34 P6, decision #149).
const placementFolders = {'Documents', 'Music', 'Videos'};

/// Where an incoming share may be mounted: a direct child of `Shared/`, or of
/// `Documents`, `Music` or `Videos` (spec #34 P6). The shape only: whether a
/// folder in those three IS a mount comes from the incoming list alone.
bool isMountPlace(String path) =>
    isIncomingMount(path) || isPlacedMountPlace(path);

/// A direct child of `Documents`, `Music` or `Videos`.
bool isPlacedMountPlace(String path) {
  final parent = p.posix.dirname(path);
  return placementFolders.contains(parent) && path != parent;
}

/// `Shared` or anything beneath it.
bool inSharedFolder(String path) =>
    path == sharedFolder || p.posix.isWithin(sharedFolder, path);

/// The incoming mount holding [path] (`Shared/<folder>`), or null.
String? incomingMountOf(String path) {
  final parts = path.split('/');
  return parts.length >= 2 && parts.first == sharedFolder
      ? '${parts[0]}/${parts[1]}'
      : null;
}

/// Nextcloud `oc:permissions` letters: W write (file), C create file, K
/// create folder. A file without W, or a folder without C and K, is View only.
bool permissionsViewOnly(String permissions, {required bool directory}) =>
    directory
    ? !permissions.contains('C') && !permissions.contains('K')
    : !permissions.contains('W');

/// Row and conflict wording (spec #26, decision #79 (a), #80 (2)).
const viewOnlyConflict =
    'View only: this change stays on this device and is not uploaded';
const viewOnlyRestoring =
    'View only: deletions are not uploaded. Restoring from the cloud.';
const viewOnlyRestored =
    'Restored from the cloud: this shared folder is View only.';
const sharedFolderRestoring = 'Restoring this shared folder from the cloud.';
const leavingShare =
    "Leaving this shared folder. The owner's folder is not changed.";
const renamingForEveryone = 'Renaming this shared folder for everyone.';
const sharedFolderInside =
    'A folder shared with you is inside: restored from the cloud, not deleted.';
const ownerUnavailableStatus = "The owner's account is disabled";
