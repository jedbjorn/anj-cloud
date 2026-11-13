import '../state/model.dart';
import '../local/root_tree.dart';
import 'sharing.dart';

/// One item of the account's own Nextcloud trash that was deleted from under
/// anj-cloud/ (spec #44): the gateway lists nothing else.
class ServerTrashItem {
  const ServerTrashItem({
    required this.id,
    required this.path,
    required this.folder,
    required this.size,
    required this.deleted,
    required this.expires,
  });

  final String id;

  /// The original path below the root.
  final String path;
  final bool folder;
  final int size;

  /// Unix seconds.
  final int deleted;
  final int expires;

  static ServerTrashItem fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        !RegExp(r'^[0-9]{1,19}$').hasMatch(value['id'] as String) ||
        value['path'] is! String ||
        value['size'] is! int ||
        value['deleted'] is! int ||
        value['expires'] is! int ||
        !const {'file', 'folder'}.contains(value['kind'])) {
      throw const CloudFailure('Invalid trash response.');
    }
    final path = value['path'] as String;
    validateRelative(path);
    return ServerTrashItem(
      id: value['id'] as String,
      path: path,
      folder: value['kind'] == 'folder',
      size: value['size'] as int,
      deleted: value['deleted'] as int,
      expires: value['expires'] as int,
    );
  }
}

class ServerTrash {
  const ServerTrash(this.trashDays, this.items);
  final int trashDays;
  final List<ServerTrashItem> items;

  static ServerTrash fromJson(Object? value) {
    if (value is! Map ||
        value['trash_days'] is! int ||
        (value['trash_days'] as int) < 1 ||
        value['items'] is! List) {
      throw const CloudFailure('Invalid trash response.');
    }
    return ServerTrash(value['trash_days'] as int, [
      for (final item in value['items'] as List) ServerTrashItem.fromJson(item),
    ]);
  }
}

/// The result of one server restore: where the item now is.
class TrashRestore {
  const TrashRestore(this.path, {required this.renamed});
  final String path;

  /// Restored under `name (restored).ext`: the original name was taken.
  final bool renamed;
}

/// The gateway's `/trash/` routes (spec #44) over this device's certificate.
abstract interface class TrashApi {
  /// Null when the gateway has no trash routes (an older server).
  Future<ServerTrash?> listTrash();
  Future<TrashRestore> restoreTrash(String id);
  Future<void> deleteTrash(String id);
  Future<int> emptyTrash();
}

/// The id is a number; anything else never reaches a URL.
String trashId(String id) => RegExp(r'^[0-9]{1,19}$').hasMatch(id)
    ? id
    : throw const CloudFailure('Not in Trash');

/// Forwards the trash routes through a wrapping cloud (renewable identity,
/// the pause gate, transfer activity) to the connection that has them,
/// passing the wrapper's own gate first like sharing does.
mixin ForwardTrash on ForwardSharing implements TrashApi {
  TrashApi get _trash {
    beforeSharing();
    final target = sharingTarget;
    if (target is TrashApi) return target as TrashApi;
    throw const CloudFailure('Trash is not available on this connection.');
  }

  @override
  Future<ServerTrash?> listTrash() async {
    beforeSharing();
    final target = sharingTarget;
    return target is TrashApi ? (target as TrashApi).listTrash() : null;
  }

  @override
  Future<TrashRestore> restoreTrash(String id) => _trash.restoreTrash(id);
  @override
  Future<void> deleteTrash(String id) => _trash.deleteTrash(id);
  @override
  Future<int> emptyTrash() => _trash.emptyTrash();
}
