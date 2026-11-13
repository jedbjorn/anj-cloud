import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'admin_api.dart';
import 'cloud_api.dart';
import 'fetch_api.dart';
import 'releases_api.dart';
import '../state/model.dart';
import '../sync/name_policy.dart';
import '../local/root_tree.dart';
import '../update/release.dart';
import 'sharing.dart';
import 'trash_api.dart';

/// The listing's explicit PROPFIND body. Every property the engine relies on
/// (type, version, size) plus the modification time and file ID that rank
/// Recent and New (spec #24), and the permissions and share types of
/// directory sharing (spec #26). Nextcloud's default (allprop) response also
/// carries getcontenttype, which nothing reads.
const listingPropfind =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
    '<d:resourcetype/><d:getetag/><d:getcontentlength/><d:getlastmodified/>'
    '<oc:fileid/><oc:permissions/><oc:share-types/></d:prop></d:propfind>';

/// The longest a cloud listing trusts stored folder ETags before walking
/// every folder again (spec #33 I4; a tuning value, shown in the doc).
const listingFullWalkInterval = Duration(hours: 6);

/// One folder as a complete listing saw it (flag SC-057): the folder as its
/// parent listed it (null for the root) and its direct children.
class ListedFolder {
  ListedFolder(this.self, this.children);
  final RemoteItem? self;
  final List<RemoteItem> children;

  /// It, or anything beneath it, reached this account by a share.
  bool holdsShare = false;

  /// The same folder at the same version: ETag, and file ID when known.
  bool matches(RemoteItem item) =>
      self != null &&
      item.kind == ItemKind.directory &&
      self!.etag == item.etag &&
      self!.fileId == item.fileId;
}

/// The first-sync listing (decision #118): the listing's properties plus
/// `oc:size`, Nextcloud's total size of a folder.
const firstSyncPropfind =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
    '<d:resourcetype/><d:getetag/><d:getcontentlength/><d:getlastmodified/>'
    '<oc:fileid/><oc:permissions/><oc:share-types/><oc:size/>'
    '</d:prop></d:propfind>';

class DavCloud
    implements
        CloudApi,
        SharingApi,
        AdminTransport,
        ReleaseTransport,
        FetchTransport,
        TrashApi {
  DavCloud(
    this.origin,
    SecurityContext context, {
    this.folderDeletionQualified = false,
    this.fullWalkInterval = listingFullWalkInterval,
    this.pruneShares = true,
    Duration Function()? monotonic,
    DateTime Function()? wallClock,
  }) : client = HttpClient(context: context),
       monotonic = monotonic ?? _uptime,
       wallClock = wallClock ?? DateTime.now {
    if (origin.scheme != 'https' ||
        origin.userInfo.isNotEmpty ||
        origin.query.isNotEmpty ||
        origin.fragment.isNotEmpty ||
        (origin.path != '' && origin.path != '/')) {
      throw const FormatException(
        'Use an HTTPS server origin without a path, credentials or query.',
      );
    }
    client.connectionTimeout = const Duration(seconds: 10);
    client.autoUncompress = false;
  }
  final Uri origin;
  final HttpClient client;
  final bool folderDeletionQualified;

  /// The longest a listing may trust stored folder ETags (flag SC-057).
  final Duration fullWalkInterval;

  /// Whether a folder holding an incoming share may reuse its stored
  /// subtree. Spec #33 I4 allows it only once an owner's change is proven to
  /// reach the recipient's folder ETags: on the review stack (Nextcloud
  /// 33.0.10) an owner's edit, create and delete six folders inside a share
  /// changed the recipient's `Shared`, mount and inner folder ETags at once
  /// (deploy/incremental_listing_fixture.py). False lists every folder
  /// holding a share on every check.
  final bool pruneShares;

  /// A clock that never steps (test seam). It does not advance while the
  /// device is suspended, so [wallClock] bounds the interval too.
  final Duration Function() monotonic;

  /// The wall clock (test seam); a backward step is ignored.
  final DateTime Function() wallClock;
  static final _clock = Stopwatch()..start();
  static Duration _uptime() => _clock.elapsed;
  Uri uri(String path) {
    if (path.isNotEmpty) validateRelative(path);
    // Every name is sent in NFC, the cloud's spelling (decision #138).
    return origin.replace(
      pathSegments: [
        'dav',
        ...path.isEmpty ? [''] : path.split('/').map(NamePolicy.nfc),
      ],
    );
  }

  Future<HttpClientResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    File? source,
    List<int>? body,
  }) async {
    final HttpClientResponse response;
    try {
      final req = await client.openUrl(method, uri(path));
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (source != null) {
        req.contentLength = await source.length();
        await req.addStream(source.openRead());
      } else if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      try {
        response = await req.close().timeout(const Duration(seconds: 30));
      } on TimeoutException {
        req.abort();
        throw const TransferInterrupted(
          'Server did not respond. Work remains pending.',
          TransferFailure.timeout,
        );
      }
    } catch (_) {
      // The connection failed: whatever changed meanwhile is unknown, so
      // the next listing walks every folder (a reconnect, flag SC-057).
      forgetListing();
      rethrow;
    }
    final limit = int.tryParse(
      response.headers.value(uploadLimitHeader)?.trim() ?? '',
    );
    if (limit != null && limit > 0) uploadLimit = limit;
    return response;
  }

  /// Reported on every response by gateways that refuse oversized uploads
  /// up front (SC-028).
  static const uploadLimitHeader = 'x-anj-upload-limit';

  @override
  int? uploadLimit;

  Future<String> boundedBody(HttpClientResponse response) async {
    final data = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (data.length + chunk.length > 2 * 1024 * 1024) {
        throw const CloudFailure(
          'Server listing exceeds the supported response size.',
        );
      }
      data.addAll(chunk);
    }
    return utf8.decode(data);
  }

  static String failureMessage(int status) => switch (status) {
    401 ||
    403 => 'Access denied or device revoked. Pending edits are retained.',
    412 => 'Remote content changed. Reconciliation is required.',
    507 => 'Cloud storage is full. Pending edits are retained.',
    _ => 'Cloud request failed ($status). Pending work is retained.',
  };

  /// A 422 `name-not-portable` (decision #120) becomes [NameNotPortable];
  /// any other 422 is an ordinary failure.
  Future<void> nameRefusal(HttpClientResponse response) async {
    Object? body;
    try {
      body = jsonDecode(await boundedBody(response));
    } on FormatException {
      /* Not the gateway's refusal. */
    } on IOException {
      /* The status alone is not enough to name the reason. */
    }
    if (body is Map && body['error'] == 'name-not-portable') {
      throw NameNotPortable(NameProblem.fromReason(body['reason']));
    }
    failure(422);
  }

  Never failure(int status) =>
      throw CloudFailure(failureMessage(status), status: status);

  /// The cloud tree as the last complete listing saw it, by folder path
  /// (`''` is the root); null until a listing completes, and again after any
  /// listing error or failed request (flag SC-057). Kept in memory only, so
  /// every engine start begins with a full walk.
  Map<String, ListedFolder>? _listing;

  /// When the last full walk completed, on [monotonic] and [wallClock].
  Duration? _lastFullWalk;
  DateTime? _lastFullWalkWall;

  /// Advanced by every [forgetListing]: a snapshot stores its listing only
  /// if no forget happened while it ran.
  int _generation = 0;

  /// The last incoming-share list read; a change forces a full walk.
  String? _incomingFingerprint;

  /// Full walks completed and folders reused unlisted (test seam, metrics).
  int fullWalks = 0;
  int foldersReused = 0;

  /// Snapshots running now; a share change during one forgets everything.
  int _listingsRunning = 0;

  /// Each outgoing share's path, from the last reads and writes of them.
  final Map<String, String> _sharePaths = {};

  /// A share of [path] was created, changed or removed here. Sharing
  /// changes no ETag (review stack, Nextcloud 33.0.10), and the item's share
  /// types are in its parent's listing, so the folders from the root down to
  /// its parent are listed again; the rest stays stored. An unknown path, or
  /// a listing running now, forgets everything instead.
  void _shareChanged(String? path) {
    final listing = _listing;
    if (path == null || listing == null || _listingsRunning > 0) {
      forgetListing();
      return;
    }
    // Stored under the cloud's spelling, NFC (decision #138), as [uri] sends.
    var parent = p.posix.dirname(path.split('/').map(NamePolicy.nfc).join('/'));
    while (parent != '.') {
      listing.remove(parent);
      parent = p.posix.dirname(parent);
    }
    listing.remove('');
  }

  /// Forgets the stored listing: the next [snapshot] walks every folder.
  void forgetListing() {
    _listing = null;
    _generation++;
  }

  /// Due when nothing is stored, or [fullWalkInterval] has passed on the
  /// monotonic clock or forward on the wall clock (suspend stops the first;
  /// a wall clock stepped back is ignored, never trusted to postpone).
  bool get _fullWalkDue {
    final last = _lastFullWalk;
    final wall = _lastFullWalkWall;
    if (_listing == null || last == null || wall == null) return true;
    final now = monotonic();
    if (now < last || now - last >= fullWalkInterval) return true;
    final since = wallClock().difference(wall);
    return !since.isNegative && since >= fullWalkInterval;
  }

  /// The account's top-level items and the sizes the server reports for
  /// them, for the first-sync folder screen (decision #118): one Depth 1
  /// PROPFIND of the root that also asks for Nextcloud's `oc:size`, a
  /// folder's total size. An item without a reported size is absent from
  /// the map. It neither reads nor changes the stored listing.
  Future<({List<RemoteItem> items, Map<String, int> sizes})> topLevel() =>
      levelWithSizes('');

  /// [directory]'s children and the sizes the server reports for them (the
  /// first-sync screen also lists inside Documents, Music and Videos,
  /// decision #163). Neither reads nor changes the stored listing.
  Future<({List<RemoteItem> items, Map<String, int> sizes})> levelWithSizes(
    String directory,
  ) async {
    final sizes = <String, int>{};
    final items = await _listChildren(
      directory,
      propfind: firstSyncPropfind,
      sizes: sizes,
    );
    return (items: items, sizes: sizes);
  }

  /// The listing of one folder's direct children (Depth:1). Throws unless
  /// the response is complete and confined to [directory]. [sizes], with a
  /// [propfind] asking for `oc:size`, receives each child's reported size.
  Future<List<RemoteItem>> _listChildren(
    String directory, {
    String propfind = listingPropfind,
    Map<String, int>? sizes,
  }) async {
    final response = await request(
      'PROPFIND',
      directory,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(propfind),
    );
    if (response.statusCode != 207) {
      await response.drain<void>();
      failure(response.statusCode);
    }
    final body = await boundedBody(response);
    if (body.contains('<!DOCTYPE') || body.contains('<!ENTITY')) {
      throw const CloudFailure('Unsupported XML declarations.');
    }
    final xml = XmlDocument.parse(body);
    if (xml.rootElement.name.local != 'multistatus') {
      throw const CloudFailure('Incomplete cloud listing.');
    }
    final children = <RemoteItem>[];
    var sawDirectory = false;
    for (final node in xml.rootElement.childElements.where(
      (e) => e.name.local == 'response',
    )) {
      final href = node.childElements
          .where((e) => e.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href == null) {
        throw const CloudFailure('Cloud response omitted a path.');
      }
      final link = origin.resolve(href);
      if (link.scheme != origin.scheme ||
          link.host != origin.host ||
          link.port != origin.port ||
          link.query.isNotEmpty ||
          link.fragment.isNotEmpty) {
        throw const CloudFailure('Cloud returned a foreign path.');
      }
      final segments = link.pathSegments.toList();
      if (segments.lastOrNull == '') segments.removeLast();
      if (segments.isEmpty ||
          segments.removeAt(0) != 'dav' ||
          segments.any((s) => s.contains('/') || s.contains('\x00'))) {
        throw const CloudFailure('Ambiguous cloud path.');
      }
      final path = segments.join('/');
      if (path.isNotEmpty) validateRelative(path);
      final propstat = node.childElements
          .where((e) => e.name.local == 'propstat')
          .where(
            (e) => e.childElements.any(
              (s) =>
                  s.name.local == 'status' &&
                  RegExp(r'\s200\s').hasMatch(s.innerText),
            ),
          )
          .firstOrNull;
      if (propstat == null) {
        throw const CloudFailure(
          'Cloud listing contains an inaccessible item.',
        );
      }
      if (path == directory) {
        sawDirectory = true;
        continue;
      }
      if (p.posix.dirname(path) != (directory.isEmpty ? '.' : directory)) {
        throw const CloudFailure(
          'Cloud listing escaped its requested directory.',
        );
      }
      final prop = propstat.childElements
          .where((e) => e.name.local == 'prop')
          .first;
      String? property(String name) => prop.childElements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText;
      final etag = property('getetag');
      if (etag == null || etag.isEmpty) {
        throw const CloudFailure('Cloud listing omitted a version.');
      }
      final isDirectory = prop.descendants.whereType<XmlElement>().any(
        (e) => e.name.local == 'collection',
      );
      final fileId = int.tryParse(property('fileid') ?? '');
      final permissions = property('permissions');
      final shareTypes = prop.childElements
          .where((e) => e.name.local == 'share-types')
          .firstOrNull;
      final size = int.tryParse(property('size') ?? '');
      if (sizes != null && size != null && size >= 0) sizes[path] = size;
      children.add(
        RemoteItem(
          path,
          isDirectory ? ItemKind.directory : ItemKind.file,
          etag,
          size: int.tryParse(property('getcontentlength') ?? '') ?? 0,
          fileId: fileId != null && fileId > 0 ? fileId : null,
          modified: parseHttpDate(property('getlastmodified')),
          permissions:
              permissions != null &&
                  RegExp(r'^[A-Z]{0,16}$').hasMatch(permissions)
              ? permissions
              : null,
          shared:
              shareTypes != null &&
              shareTypes.childElements.any((e) => e.name.local == 'share-type'),
        ),
      );
    }
    if (!sawDirectory) {
      throw const CloudFailure(
        'Cloud listing did not confirm the requested directory.',
      );
    }
    return children;
  }

  /// The whole tree (flag SC-057). The root is always listed. A folder whose
  /// ETag and file ID equal those the last complete listing recorded for it
  /// reuses that listing's subtree without a request: Nextcloud changes a
  /// folder's ETag whenever anything beneath it changes. Incoming shares
  /// are reused only when [pruneShares] (their owner's changes reach the
  /// recipient's folder ETags); otherwise every folder holding one is
  /// listed. A full walk runs when nothing is stored (engine start, after
  /// an error or failed request, after the incoming shares changed) and at
  /// least every [fullWalkInterval]. Only a listing that completes is
  /// stored, so a partial listing never seeds a later one.
  @override
  Future<List<RemoteItem>> snapshot() async {
    _listingsRunning++;
    try {
      return await _snapshot();
    } finally {
      _listingsRunning--;
    }
  }

  Future<List<RemoteItem>> _snapshot() async {
    final previous = _fullWalkDue ? null : _listing;
    _listing = null;
    final generation = _generation;
    final folders = <String, ListedFolder>{};
    final entries = <String, RemoteItem>{};
    void add(RemoteItem item) {
      if (entries.containsKey(item.path)) {
        throw const CloudFailure('Duplicate cloud listing path.');
      }
      entries[item.path] = item;
      if (entries.length > 100000) {
        throw const CloudFailure(
          'Cloud tree exceeds the supported listing size.',
        );
      }
    }

    // Folders still to visit: the item as its parent listed it (null for
    // the root), read before any of its children.
    final pending = <(String, RemoteItem?)>[('', null)];
    while (pending.isNotEmpty) {
      final (directory, self) = pending.removeLast();
      final stored = previous?[directory];
      if (self != null &&
          stored != null &&
          stored.matches(self) &&
          (pruneShares || !stored.holdsShare)) {
        // Unchanged since the last complete listing: its stored subtree.
        final reuse = [directory];
        while (reuse.isNotEmpty) {
          final path = reuse.removeLast();
          final folder = previous![path]!;
          folders[path] = folder;
          foldersReused++;
          for (final child in folder.children) {
            add(child);
            if (child.kind != ItemKind.directory) continue;
            final inner = previous[child.path];
            if (inner != null && inner.matches(child)) {
              reuse.add(child.path);
            } else {
              pending.add((child.path, child)); // never stored: listed
            }
          }
        }
        continue;
      }
      final children = await _listChildren(directory);
      folders[directory] = ListedFolder(self, children);
      for (final child in children) {
        add(child);
        if (child.kind == ItemKind.directory) {
          pending.add((child.path, child));
        }
      }
    }
    // Deepest first, so each folder sees its subfolders' answer.
    final order = folders.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final path in order) {
      final folder = folders[path]!;
      folder.holdsShare =
          _sharedWithMe(folder.self) ||
          folder.children.any(
            (child) =>
                _sharedWithMe(child) ||
                (folders[child.path]?.holdsShare ?? false),
          );
    }
    // A forget while this listing ran (a failed request, a share change)
    // means it may already be stale: return it, but never store it.
    if (generation == _generation) {
      _listing = folders;
      if (previous == null) {
        _lastFullWalk = monotonic();
        _lastFullWalkWall = wallClock();
        fullWalks++;
      }
    }
    return entries.values.toList();
  }

  /// Nextcloud's `S` permission: the item reached this account by a share.
  static bool _sharedWithMe(RemoteItem? item) =>
      item?.permissions?.contains('S') ?? false;

  @override
  Future<void> download(
    String path,
    File target, {
    required String etag,
  }) async {
    final response = await request(
      'GET',
      path,
      headers: {'If-Match': etag, 'Accept-Encoding': 'identity'},
    );
    if (response.statusCode != 200) {
      await response.drain<void>();
      failure(response.statusCode);
    }
    if (response.headers.value('etag') != etag) {
      await response.drain<void>();
      throw const CloudFailure('Download version changed.');
    }
    final sink = target.openWrite();
    try {
      await sink.addStream(response.timeout(const Duration(seconds: 30)));
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (response.contentLength >= 0 &&
        await target.length() != response.contentLength) {
      throw const CloudFailure('Incomplete download retained for retry.');
    }
    final file = await target.open(mode: FileMode.append);
    await file.flush();
    await file.close();
  }

  @override
  bool lastUploadReadBack = false;

  @override
  Future<String> upload(
    String path,
    File source, {
    required String? etag,
  }) async {
    lastUploadReadBack = false;
    // A file over the limit the server reported is never sent (SC-028).
    final size = await source.length();
    final known = uploadLimit;
    if (known != null && size > known) {
      throw UploadTooLarge(limit: known, size: size);
    }
    final HttpClientResponse response;
    try {
      response = await request(
        'PUT',
        path,
        headers: {if (etag == null) 'If-None-Match': '*' else 'If-Match': etag},
        source: source,
      );
    } on IOException catch (error) {
      // HttpClient reads no response until the whole body is sent, so a
      // server that refuses mid-body shows up here as a broken connection.
      throw TransferInterrupted('$error', TransferFailure.write);
    }
    if (response.statusCode == 422) await nameRefusal(response);
    if (response.statusCode == 413) {
      var limit = uploadLimit;
      int? actual;
      try {
        final error =
            jsonDecode(await boundedBody(response)) as Map<String, dynamic>;
        final maximum = error['max_bytes'];
        if (error['error'] == 'transfer_limit' && maximum is int) {
          if (maximum > 0) limit ??= maximum;
          if (error['actual_bytes'] case final int bytes when bytes >= 0) {
            actual = bytes;
          }
        }
      } on FormatException {
        /* The status alone is enough. */
      } on IOException {
        /* The status alone is enough. */
      }
      throw UploadTooLarge(limit: limit, size: actual ?? size);
    }
    await response.drain<void>();
    if (response.statusCode >= 500) {
      throw TransferInterrupted(
        failureMessage(response.statusCode),
        TransferFailure.server,
        status: response.statusCode,
      );
    }
    if (response.statusCode != 201 && response.statusCode != 204) {
      failure(response.statusCode);
    }
    var version = response.headers.value('etag');
    if (version == null) {
      lastUploadReadBack = true;
      final head = await request('HEAD', path);
      await head.drain<void>();
      if (head.statusCode != 200) failure(head.statusCode);
      version = head.headers.value('etag');
    }
    if (version == null) {
      throw const CloudFailure(
        'Upload acknowledgement omitted its version. Reconciliation is pending.',
      );
    }
    return version;
  }

  @override
  Future<void> mkdir(String path) async {
    final response = await request(
      'MKCOL',
      path,
      headers: {'If-None-Match': '*'},
    );
    if (response.statusCode == 422) await nameRefusal(response);
    await response.drain<void>();
    if (response.statusCode != 201) {
      failure(response.statusCode);
    }
  }

  @override
  Future<void> deleteFile(String path, {required String etag}) async {
    final response = await request('DELETE', path, headers: {'If-Match': etag});
    await response.drain<void>();
    if (response.statusCode != 204 && response.statusCode != 404) {
      failure(response.statusCode);
    }
  }

  /// A conditional `MOVE` with `Overwrite: F`, both names in NFC. The
  /// gateway refuses a target name that clashes with another sibling (422
  /// `name-not-portable`); a rename of the same item that changes only its
  /// case is allowed.
  @override
  Future<void> move(String from, String to, {required String etag}) async {
    final response = await request(
      'MOVE',
      from,
      headers: {
        'If-Match': etag,
        'Overwrite': 'F',
        'Destination': uri(to).toString(),
      },
    );
    if (response.statusCode == 422) await nameRefusal(response);
    await response.drain<void>();
    if (response.statusCode != 201 && response.statusCode != 204) {
      failure(response.statusCode);
    }
  }

  @override
  bool get safeFolderDeletion => folderDeletionQualified;
  @override
  Future<void> deleteFolder(
    String path, {
    required Map<String, String> versions,
  }) async {
    if (!safeFolderDeletion) {
      throw const CloudFailure(
        'Concurrent folder deletion qualification is pending.',
      );
    }
    final etag = versions[path];
    if (etag == null || etag == '*') {
      throw const CloudFailure('Folder deletion requires a concrete baseline.');
    }
    await deleteFile(path, etag: etag);
  }

  /// `GET /v1/files/added` (decision #56). A 404 is an older gateway: no
  /// dates, no error.
  @override
  Future<AddedPage?> addedSince(int after) async {
    final req = await client.getUrl(
      origin.replace(
        path: '/v1/files/added',
        queryParameters: {'after': '$after'},
      ),
    );
    req.followRedirects = false;
    final HttpClientResponse response;
    try {
      response = await req.close().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      req.abort();
      throw const CloudFailure('Server did not respond.');
    }
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      failure(response.statusCode);
    }
    return parseAddedPage(await boundedBody(response));
  }

  /// One sharing route (spec #26): JSON in and out, bounded, no query string.
  /// A refusal carries the gateway's curated message and status.
  Future<Object?> _sharing(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool missingIsNull = false,
  }) async {
    final req = await client.openUrl(method, origin.replace(path: path));
    req.followRedirects = false;
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final HttpClientResponse response;
    try {
      response = await req.close().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      req.abort();
      throw const CloudFailure('Server did not respond.');
    }
    if (missingIsNull && response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    final text = await boundedBody(response);
    Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      data = null;
    }
    if (response.statusCode < 200 || response.statusCode > 299) {
      final error = data is Map ? data['error'] : null;
      throw CloudFailure(
        error is String && error.isNotEmpty
            ? error
            : failureMessage(response.statusCode),
        status: response.statusCode,
      );
    }
    return data;
  }

  List<Object?> _list(Object? data) => data is List
      ? data
      : throw const CloudFailure('Invalid sharing response.');

  @override
  Future<List<IncomingShare>?> incomingShares() async {
    final data = await _sharing(
      'GET',
      '/v1/shares/incoming',
      missingIsNull: true,
    );
    final shares = data == null
        ? null
        : _list(data).map(IncomingShare.fromJson).toList();
    // A share added, removed or changed: walk everything next (SC-057).
    final fingerprint = jsonEncode([
      for (final share in shares ?? const <IncomingShare>[]) share.toJson(),
    ]);
    if (fingerprint != _incomingFingerprint) forgetListing();
    _incomingFingerprint = fingerprint;
    return shares;
  }

  @override
  Future<List<OutgoingShare>> outgoingShares() async {
    final shares = _list(await _sharing('GET', '/v1/shares/outgoing'))
        .map(OutgoingShare.fromJson)
        .toList();
    _sharePaths
      ..clear()
      ..addEntries(shares.map((share) => MapEntry(share.shareId, share.path)));
    return shares;
  }

  @override
  Future<List<HouseholdUser>> householdUsers() async =>
      _list(await _sharing('GET', '/v1/household/users'))
          .map(HouseholdUser.fromJson)
          .toList();

  @override
  Future<OutgoingShare> createShare(
    String path,
    String recipientId,
    SharePermission permission,
  ) async {
    validateRelative(path);
    // Whatever the outcome (a lost answer may still have shared it).
    try {
      final share = OutgoingShare.fromJson(
        await _sharing(
          'POST',
          '/v1/shares',
          body: {
            'path': path,
            'recipient_id': recipientId,
            'permission': permission.name,
          },
        ),
      );
      _sharePaths[share.shareId] = share.path;
      return share;
    } finally {
      _shareChanged(path);
    }
  }

  static String _shareId(String id) => RegExp(r'^[0-9]{1,19}$').hasMatch(id)
      ? id
      : throw const CloudFailure('Invalid share.');

  @override
  Future<OutgoingShare> updateShare(
    String shareId,
    SharePermission permission,
  ) async {
    try {
      return OutgoingShare.fromJson(
        await _sharing(
          'PATCH',
          '/v1/shares/${_shareId(shareId)}',
          body: {'permission': permission.name},
        ),
      );
    } finally {
      _shareChanged(_sharePaths[shareId]);
    }
  }

  @override
  Future<void> removeShare(String shareId) async {
    try {
      await _sharing('DELETE', '/v1/shares/${_shareId(shareId)}');
    } finally {
      _shareChanged(_sharePaths.remove(shareId));
    }
  }

  @override
  Future<void> leaveShare(String shareId) async {
    try {
      await _sharing('DELETE', '/v1/shares/incoming/${_shareId(shareId)}');
    } finally {
      // The mount leaves the listing: walk everything next (SC-057).
      forgetListing();
    }
  }

  @override
  Future<String?> renameForEveryone(String shareId, String name) async {
    try {
      final data = await _sharing(
        'POST',
        '/v1/shares/incoming/${_shareId(shareId)}/rename',
        body: {'name': name},
      );
      final path = data is Map ? data['path'] : null;
      if (path is String) {
        validateRelative(path);
        if (!isMountPlace(path)) {
          throw const CloudFailure('Invalid sharing response.');
        }
        return path;
      }
      return null;
    } finally {
      forgetListing();
    }
  }

  /// One household-administration request (spec #27): JSON in and out,
  /// bounded, this device's certificate. Every status is returned with its
  /// body so the caller can act on 428 confirmations and 409 refusals.
  @override
  Future<AdminResponse> admin(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    if (!adminPathAllowed(path)) {
      throw const CloudFailure('Invalid admin request.');
    }
    final req = await client.openUrl(method, origin.resolve(path));
    req.followRedirects = false;
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final HttpClientResponse response;
    try {
      // The gateway answers within its hold; a longer action answers 202 and
      // AdminClient polls it (SC-041).
      response = await req.close().timeout(adminRequestTimeout);
    } on TimeoutException {
      req.abort();
      throw const CloudFailure('Server did not respond.');
    }
    final text = await boundedBody(response);
    Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      data = null;
    }
    return AdminResponse(response.statusCode, data);
  }

  /// The update feed (spec #28 G1, spec #37) over this device's certificate.
  @override
  Future<ReleaseManifest?> releaseManifest(String target) =>
      fetchReleaseManifest(client, origin, target);

  @override
  Future<void> downloadRelease(
    ReleaseManifest manifest,
    File destination, {
    void Function(int received)? progress,
    Future<void>? cancel,
  }) => downloadReleasePackage(
    client,
    origin,
    manifest,
    destination,
    progress: progress,
    cancel: cancel,
  );

  /// Media fetch job routes (spec #42) over this device's certificate.
  late final _fetch = HttpFetchTransport(client, origin);
  @override
  Future<List<FetchJob>?> listFetchJobs() => _fetch.listFetchJobs();
  @override
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  }) => _fetch.submitFetchJobs(urls, kind, resolution: resolution);
  @override
  Future<void> deleteFetchJob(String id) => _fetch.deleteFetchJob(id);
  @override
  Future<void> clearFetchJobs() => _fetch.clearFetchJobs();

  /// Trash (spec #44): the gateway's `/trash/` routes. A restore changes the
  /// tree, so the next listing walks every folder (SC-057).
  @override
  Future<ServerTrash?> listTrash() async {
    final data = await _sharing('GET', '/trash/', missingIsNull: true);
    return data == null ? null : ServerTrash.fromJson(data);
  }

  @override
  Future<TrashRestore> restoreTrash(String id) async {
    try {
      final data = await _sharing('POST', '/trash/${trashId(id)}/restore');
      if (data is! Map || data['path'] is! String) {
        throw const CloudFailure('Invalid trash response.');
      }
      final path = data['path'] as String;
      validateRelative(path);
      return TrashRestore(path, renamed: data['renamed'] == true);
    } finally {
      forgetListing();
    }
  }

  @override
  Future<List<TrashRestoreResult>> restoreTrashMany(List<String> ids) async {
    final results = <TrashRestoreResult>[];
    try {
      // The gateway takes at most 500 per request.
      for (var start = 0; start < ids.length; start += 500) {
        final chunk = [for (final id in ids.skip(start).take(500)) trashId(id)];
        final data = await _sharing(
          'POST',
          '/trash/restore',
          body: {'ids': chunk},
        );
        results.addAll(parseRestoreMany(data, chunk));
      }
      return results;
    } finally {
      forgetListing();
    }
  }

  @override
  Future<void> deleteTrash(String id) async {
    await _sharing('DELETE', '/trash/${trashId(id)}');
  }

  @override
  Future<int> emptyTrash() async {
    final data = await _sharing('DELETE', '/trash/');
    final deleted = data is Map ? data['deleted'] : null;
    return deleted is int ? deleted : 0;
  }

  @override
  void close() {
    forgetListing();
    client.close(force: true);
  }
}

/// `getlastmodified` (an HTTP date) as Unix seconds; null when absent or
/// malformed, which only leaves the entry undated.
int? parseHttpDate(String? value) {
  if (value == null) return null;
  try {
    return HttpDate.parse(value).millisecondsSinceEpoch ~/ 1000;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

/// Strict parse of a `/v1/files/added` page; anything unexpected fails the
/// fetch (and only the fetch: New keeps its order and existing dates).
AddedPage parseAddedPage(String body) {
  const invalid = CloudFailure('Invalid added-time response.');
  final Object? data;
  try {
    data = jsonDecode(body);
  } on FormatException {
    throw invalid;
  }
  if (data is! Map ||
      data['added'] is! Map ||
      data['cursor'] is! int ||
      (data['cursor'] as int) < 0 ||
      data['more'] is! bool ||
      (data['reset'] ?? false) is! bool) {
    throw invalid;
  }
  final added = <int, int>{};
  for (final row in (data['added'] as Map).entries) {
    final id = int.tryParse(row.key as String);
    final at = row.value;
    if (id == null || id <= 0 || at is! num || at < 0 || !at.isFinite) {
      throw invalid;
    }
    added[id] = at.floor();
  }
  return AddedPage(
    added,
    cursor: data['cursor'] as int,
    more: data['more'] as bool,
    reset: data['reset'] as bool? ?? false,
  );
}

const _invitationAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

// Invitation code sizes (decision #151, spec #35): the client's twin of
// services/access/codes.py. Changing the code's size is these two constants
// plus PINNED_SECRET_BYTES / CA_PIN_BYTES there (then regenerate
// tests/pairing_code_vector.json); every length is derived. Whole bytes.

/// The one-time secret of a pinned code.
const pinnedSecretBytes = 7;

/// The prefix of the household CA certificate's SHA-256 a pinned code carries.
const caPinBytes = 10;

/// Codes issued before decision #151 (fingerprint approval, rule 6).
const legacySecretBytes = 20;

/// Characters for [size] bytes, 5 bits each: ceil(bits / 5).
int invitationLength(int size) => (size * 8 + 4) ~/ 5;

/// A legacy invitation: the one-time secret only.
const legacyInvitationLength = (legacySecretBytes * 8 + 4) ~/ 5;

/// A pinned invitation: the secret plus the CA pin, in the same alphabet.
/// Never the legacy length: the two formats are told apart by length.
const pinnedInvitationLength = ((pinnedSecretBytes + caPinBytes) * 8 + 4) ~/ 5;

/// The canonical form of a typed or pasted code: separators and case do not
/// matter. Throws [FormatException] for anything that is not a code.
String normalizeInvitation(String value) {
  if (value.length > 128) {
    throw const FormatException('The code is too long.');
  }
  assert(
    pinnedInvitationLength != legacyInvitationLength,
    'A pinned code must not have the legacy length.',
  );
  final normalized = value
      .replaceAll('-', '')
      .replaceAll(' ', '')
      .toUpperCase();
  if ((normalized.length != legacyInvitationLength &&
          normalized.length != pinnedInvitationLength) ||
      !RegExp(r'^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]+$').hasMatch(normalized)) {
    throw const FormatException(
      'Enter the pairing code; spaces and hyphens are allowed.',
    );
  }
  return normalized;
}

/// The CA pin a normalized pinned code carries, or null for a legacy code.
List<int>? invitationCaPin(String normalized) {
  if (normalized.length != pinnedInvitationLength) return null;
  var number = BigInt.zero;
  for (final char in normalized.split('')) {
    number = (number << 5) | BigInt.from(_invitationAlphabet.indexOf(char));
  }
  const total = pinnedSecretBytes + caPinBytes;
  if (number >> (total * 8) != BigInt.zero) {
    throw const FormatException('Code not valid.');
  }
  final bytes = List<int>.filled(total, 0);
  for (var i = total - 1; i >= 0; i--) {
    bytes[i] = (number & BigInt.from(0xff)).toInt();
    number = number >> 8;
  }
  return bytes.sublist(pinnedSecretBytes);
}

/// A refusal shown to the person pairing as it is.
class PairingRefused implements Exception {
  const PairingRefused(this.message);
  final String message;
  @override
  String toString() => message;
}

const notThisServer = 'This code is not for this server.';

void _checkPairingOrigin(Uri origin) {
  if (origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      origin.query.isNotEmpty ||
      origin.fragment.isNotEmpty ||
      (origin.path != '' && origin.path != '/')) {
    throw const FormatException('Use an HTTPS server origin.');
  }
}

/// The DER of the one certificate in a PEM [data], or null when it is not
/// exactly one well-formed certificate block of ASCII text.
List<int>? singleCertificateDer(List<int> data) {
  final String text;
  try {
    text = ascii.decode(data);
  } on FormatException {
    return null;
  }
  final blocks = RegExp(
    r'-----BEGIN CERTIFICATE-----([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
  ).allMatches(text).toList();
  if (blocks.length != 1) return null;
  try {
    return base64.decode(blocks.single.group(1)!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return null;
  }
}

/// The pin of a CA certificate: the first [caPinBytes] of SHA-256 over DER.
List<int> caPinOf(List<int> der) =>
    sha256.convert(der).bytes.sublist(0, caPinBytes);

bool samePin(List<int> a, List<int> b) {
  if (a.length != caPinBytes || b.length != caPinBytes) return false;
  for (var i = 0; i < caPinBytes; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Spec #35 rule 2: fetch the household CA from `GET /v1/ca` over TLS
/// without trust, and accept it only if the first [caPinBytes] of its SHA-256
/// equal the code's [pin]. Returns the one certificate as PEM, re-encoded
/// from exactly the bytes that were hashed. On any mismatch nothing is
/// returned, so nothing can be stored.
Future<String> fetchPinnedCa(Uri origin, List<int> pin) async {
  _checkPairingOrigin(origin);
  final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 10)
    // No trust yet: the pin below is the only check on what arrives.
    ..badCertificateCallback = (certificate, host, port) => true;
  try {
    final request = await client.getUrl(origin.resolve('/v1/ca'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    final data = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (data.length + chunk.length > 16 * 1024) {
        throw const PairingRefused(notThisServer);
      }
      data.addAll(chunk);
    }
    if (response.statusCode != 200) {
      throw CloudFailure(
        'The server did not provide its certificate (${response.statusCode}).',
        status: response.statusCode,
      );
    }
    final der = singleCertificateDer(data);
    if (der == null || !samePin(caPinOf(der), pin)) {
      throw const PairingRefused(notThisServer);
    }
    final encoded = base64.encode(der);
    final lines = [
      for (var i = 0; i < encoded.length; i += 64)
        encoded.substring(i, (i + 64).clamp(0, encoded.length)),
    ];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n'
        '-----END CERTIFICATE-----\n';
  } finally {
    client.close(force: true);
  }
}

/// A `Retry-After` header as a wait: whole seconds only (the gateway never
/// sends a date), at least one second and at most a day; anything else is
/// "not stated" so the caller falls back to its fixed wording.
Duration? parseRetryAfter(String? value) {
  final text = value?.trim();
  if (text == null || !RegExp(r'^\d{1,6}$').hasMatch(text)) return null;
  final seconds = int.parse(text);
  if (seconds < 1 || seconds > 86400) return null;
  return Duration(seconds: seconds);
}

class PairingClient {
  PairingClient(this.origin, SecurityContext context)
    : client = HttpClient(context: context) {
    _checkPairingOrigin(origin);
    client.connectionTimeout = const Duration(seconds: 10);
  }
  final Uri origin;
  final HttpClient client;
  Future<Map<String, dynamic>> enroll(
    String code,
    String csr, {
    String? label,
  }) async {
    code = normalizeInvitation(code);
    final req = await client.postUrl(
      origin.resolve(label == null ? '/v1/enroll/status' : '/v1/enroll'),
    );
    req.followRedirects = false;
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'code': code, 'csr': csr, 'label': ?label}));
    // The gateway holds a pinned code's exchange up to 20 s while it
    // approves the device (spec #35), so allow for that.
    final response = await req.close().timeout(const Duration(seconds: 45));
    final data = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 45))) {
      if (data.length + chunk.length > 64 * 1024) {
        throw const CloudFailure(
          'Pairing response exceeds the supported size.',
        );
      }
      data.addAll(chunk);
    }
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw CloudFailure(
        'Pairing request failed (${response.statusCode}).',
        status: response.statusCode,
        retryAfter: response.statusCode == 429
            ? parseRetryAfter(response.headers.value('retry-after'))
            : null,
      );
    }
    return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
  }

  void close() => client.close(force: true);
}
