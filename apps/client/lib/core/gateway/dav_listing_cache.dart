import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../local/root_tree.dart';
import '../state/manifest.dart';
import '../state/model.dart';

/// A folder as its parent listed it (null for the root), and its direct children.
class ListedFolder {
  ListedFolder(this.self, this.children);
  final RemoteItem? self;
  final List<RemoteItem> children;
  bool holdsShare = false;

  bool matches(RemoteItem item, {required bool persistent}) =>
      self != null &&
      item.kind == ItemKind.directory &&
      self!.etag == item.etag &&
      self!.fileId == item.fileId &&
      (!persistent ||
          (item.fileId != null &&
              self!.permissions == item.permissions &&
              self!.shared == item.shared));
}

typedef ListingAge = ({int fullWall, int fullServer, int wall, int server});

/// Optional storage for the DAV listing, under the worker's existing private
/// profile lock. The anchor records the generation's binding and digest.
/// It can be removed or advanced without rewriting
/// the tree. Profile transactions publish both rows together.
class DavListingCache {
  factory DavListingCache(Manifest profile) =>
      _forProfile[profile] ??= DavListingCache._(profile);
  DavListingCache._(this.profile);

  final Manifest profile;
  static final _forProfile = Expando<DavListingCache>();
  static const _anchor = 'davListingAnchorV1';
  static const _tree = 'davListingTreeV1';

  // Multiple transports can briefly share the worker's locked profile during
  // certificate renewal. Prevent a traversal from publishing over a newer
  // save or invalidation, including across those transports.
  int revision = 0;
  int _mutations = 0;
  bool get mutating => _mutations != 0;

  /// Pairing and key reset already run inside a profile transaction.
  static void clear(Manifest profile) {
    final cache = _forProfile[profile];
    if (cache != null) cache.revision++;
    profile.deleteSetting(_anchor, cache: true);
    profile.deleteSetting(_tree, cache: true);
  }

  String? _binding(Uri origin) {
    final server = Uri.tryParse(profile.setting('server') ?? '');
    final account = profile.setting('accountUid');
    final device = profile.setting('deviceId');
    if (server == null ||
        server.scheme != 'https' ||
        !server.hasAuthority ||
        server.origin != origin.origin ||
        account == null ||
        account.isEmpty ||
        device == null ||
        device.isEmpty) {
      return null;
    }
    return jsonEncode([
      origin.origin,
      account,
      device,
      profile.setting('fingerprint'),
      profile.setting('accountRights'),
    ]);
  }

  void invalidate() {
    revision++;
    profile.deleteSetting(_anchor, cache: true);
  }

  void beginMutation() {
    invalidate();
    _mutations++;
  }

  void endMutation() {
    _mutations--;
    // All snapshots that began during the mutation must be discarded.
    revision++;
  }

  ({Map<String, ListedFolder> folders, ListingAge age, String shares})? load(
    Uri origin,
    DateTime now,
    Duration interval,
  ) {
    final anchor = profile.setting(_anchor);
    if (anchor == null) return null;
    try {
      final meta = jsonDecode(anchor) as Map<String, dynamic>;
      final binding = _binding(origin);
      if (binding == null ||
          meta['binding'] != binding ||
          meta['format'] != 1) {
        throw const FormatException('Foreign listing generation.');
      }
      final age = (
        fullWall: meta['fullWall'] as int,
        fullServer: meta['fullServer'] as int,
        wall: meta['wall'] as int,
        server: meta['server'] as int,
      );
      final wall = now.millisecondsSinceEpoch;
      if (age.fullWall <= 0 ||
          age.fullServer <= 0 ||
          age.wall < age.fullWall ||
          age.server < age.fullServer ||
          age.wall > wall ||
          wall - age.fullWall >= interval.inMilliseconds) {
        throw const FormatException('Unverifiable listing age.');
      }
      final payload = profile.setting(_tree);
      if (payload == null || _digest(payload) != meta['digest']) {
        throw const FormatException('Damaged listing generation.');
      }
      return (
        folders: _decodeTree(payload),
        age: age,
        shares: meta['shares'] as String,
      );
    } on FormatException {
      invalidate();
    } on TypeError {
      invalidate();
    } on FileSystemException {
      invalidate();
    }
    return null;
  }

  void save(
    Uri origin,
    Map<String, ListedFolder> folders,
    ListingAge age,
    String shares, {
    required bool changed,
  }) {
    final binding = _binding(origin);
    if (binding == null) {
      invalidate();
      return;
    }
    final previous = profile.setting(_anchor);
    final previousDigest = previous == null
        ? null
        : (jsonDecode(previous) as Map)['digest'] as String;
    final payload = changed || previousDigest == null
        ? jsonEncode({
            for (final entry in folders.entries)
              entry.key: entry.value.children.map(fields).toList(),
          })
        : null;
    final anchor = jsonEncode({
      'format': 1,
      'binding': binding,
      'shares': shares,
      'fullWall': age.fullWall,
      'fullServer': age.fullServer,
      'wall': age.wall,
      'server': age.server,
      'digest': payload == null ? previousDigest : _digest(payload),
    });
    if (payload == null) {
      profile.setSetting(_anchor, anchor, cache: true);
    } else {
      profile.transaction(() {
        profile.setSetting(_tree, payload, cache: true);
        profile.setSetting(_anchor, anchor, cache: true);
      });
    }
    revision++;
  }

  static String _digest(String payload) =>
      sha256.convert(utf8.encode(payload)).toString();

  static List<Object?> fields(RemoteItem item) => [
    item.path,
    item.kind == ItemKind.directory,
    item.etag,
    item.size,
    item.fileId,
    item.modified,
    item.permissions,
    item.shared,
  ];

  static Map<String, ListedFolder> _decodeTree(String payload) {
    final stored = jsonDecode(payload) as Map<String, dynamic>;
    final folders = <String, ListedFolder>{};
    final paths = <String>{};
    final pending = <(String, RemoteItem?)>[('', null)];
    while (pending.isNotEmpty) {
      final (path, self) = pending.removeLast();
      final children = <RemoteItem>[];
      for (final row in stored[path] as List) {
        final item = _decodeItem(row as List);
        validateRelative(item.path);
        if (p.posix.dirname(item.path) != (path.isEmpty ? '.' : path) ||
            !paths.add(item.path) ||
            paths.length > 100000) {
          throw const FormatException('Invalid saved listing path.');
        }
        children.add(item);
        if (item.kind == ItemKind.directory) pending.add((item.path, item));
      }
      folders[path] = ListedFolder(self, children);
    }
    if (stored.length != folders.length) {
      throw const FormatException('Unreachable saved listing folders.');
    }
    return folders;
  }

  static RemoteItem _decodeItem(List row) {
    if (row.length != 8) throw const FormatException('Invalid saved item.');
    final item = RemoteItem(
      row[0] as String,
      row[1] as bool ? ItemKind.directory : ItemKind.file,
      row[2] as String,
      size: row[3] as int,
      fileId: row[4] as int?,
      modified: row[5] as int?,
      permissions: row[6] as String?,
      shared: row[7] as bool,
    );
    if (item.etag.isEmpty ||
        item.size < 0 ||
        (item.fileId != null && item.fileId! <= 0) ||
        (item.permissions != null &&
            !RegExp(r'^[A-Z]{0,16}$').hasMatch(item.permissions!))) {
      throw const FormatException('Invalid saved listing metadata.');
    }
    return item;
  }
}
