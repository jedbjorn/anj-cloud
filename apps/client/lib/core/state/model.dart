import 'dart:collection';

enum Retention { local, cloud }

enum ItemKind { file, directory, unsupported }

/// Receives in-place mutations of manifest rows so a save writes only the
/// rows that changed. Attached by [Manifest] when a row enters its maps.
abstract interface class RowTracker {
  void entryChanged(Entry entry);
  void operationChanged(Operation operation);
}

class LocalItem {
  const LocalItem(
    this.path,
    this.kind, {
    this.hash,
    this.size = 0,
    this.identity,
    this.links,
    this.birth,
    this.scanStamp,
    this.stamp,
    this.stampedAt,
    this.stampFinal = false,
  });
  final String path;
  final ItemKind kind;
  final String? hash;
  final int size;

  /// `volume:inode` (the NTFS file ID on Windows) from the scan.
  final String? identity;

  /// Link count from the scan (st_nlink, NumberOfLinks); null when the
  /// listing did not report it.
  final int? links;

  /// A folder's birth time (nanoseconds since the epoch) on a filesystem
  /// whose birth time is trusted (ext4, f2fs, btrfs, xfs: statx btime);
  /// null for files, on macOS (APFS never reuses inode numbers), on Windows
  /// (the NTFS file id already differs for a recreated folder) and
  /// elsewhere. Flag SC-074: ext4 and f2fs give a folder deleted and created
  /// again its old inode number; its birth time tells them apart.
  final int? birth;

  /// `volume:ino:size:mtime_ns:ctime_ns` observed by the stat scan.
  final String? scanStamp;

  /// Stamp proven to describe [hash] (null when unproven: hash next pass).
  final String? stamp;

  /// Wall-clock microseconds when [hash] was read from the file's bytes.
  final int? stampedAt;

  /// The hash was read at least the confirmation margin after the file's
  /// last ctime, so no unrecorded write can predate it (decision #38).
  final bool stampFinal;

  /// The same item listed at [path] (a move or rename applied to a view):
  /// every field kept, so a field added later is never dropped by a
  /// hand-written copy.
  LocalItem movedTo(String path) => LocalItem(
    path,
    kind,
    hash: hash,
    size: size,
    identity: identity,
    links: links,
    birth: birth,
    scanStamp: scanStamp,
    stamp: stamp,
    stampedAt: stampedAt,
    stampFinal: stampFinal,
  );
}

class RemoteItem {
  const RemoteItem(
    this.path,
    this.kind,
    this.etag, {
    this.size = 0,
    this.fileId,
    this.modified,
    this.permissions,
    this.shared = false,
  });
  final String path;
  final ItemKind kind;
  final String etag;
  final int size;

  /// Nextcloud `oc:permissions` (spec #26): which actions this account may
  /// take on the item. Null from a cloud that does not report them.
  final String? permissions;

  /// `oc:share-types` is non-empty: this account shares the item.
  final bool shared;

  /// Nextcloud `oc:fileid`: fixed across content updates and moves, and
  /// increasing with each new file, so it orders New on every device.
  final int? fileId;

  /// Cloud modification time (`getlastmodified`), Unix seconds.
  final int? modified;
}

/// One page of the gateway's added times (decision #56): file ID to the
/// gateway's UTC clock when the file was first created through it.
class AddedPage {
  const AddedPage(
    this.added, {
    required this.cursor,
    this.more = false,
    this.reset = false,
  });

  /// File ID -> Unix seconds.
  final Map<int, int> added;
  final int cursor;
  final bool more;

  /// The cursor is beyond the server's registry; start again from 0.
  final bool reset;
}

class _TrackedStrings extends ListBase<String> {
  _TrackedStrings(Iterable<String> values, this._changed)
    : _values = List<String>.of(values);
  final List<String> _values;
  final void Function() _changed;
  @override
  int get length => _values.length;
  @override
  set length(int value) {
    _values.length = value;
    _changed();
  }

  @override
  String operator [](int index) => _values[index];
  @override
  void operator []=(int index, String value) {
    _values[index] = value;
    _changed();
  }

  @override
  void add(String element) {
    _values.add(element);
    _changed();
  }

  @override
  void addAll(Iterable<String> iterable) {
    _values.addAll(iterable);
    _changed();
  }
}

class Entry {
  Entry(this.path, ItemKind kind) : _kind = kind;
  final String path;

  /// Set by the owning manifest; every field write below reports through it.
  RowTracker? tracker;
  void _changed() => tracker?.entryChanged(this);
  ItemKind _kind;
  ItemKind get kind => _kind;
  set kind(ItemKind v) {
    if (v != _kind) {
      _kind = v;
      _changed();
    }
  }

  String? _etag;
  String? get etag => _etag;
  set etag(String? v) {
    if (v != _etag) {
      _etag = v;
      _changed();
    }
  }

  String? _baselineHash;
  String? get baselineHash => _baselineHash;
  set baselineHash(String? v) {
    if (v != _baselineHash) {
      _baselineHash = v;
      _changed();
    }
  }

  String? _localHash;
  String? get localHash => _localHash;
  set localHash(String? v) {
    if (v != _localHash) {
      _localHash = v;
      _changed();
    }
  }

  bool _expectedPresent = false;
  bool get expectedPresent => _expectedPresent;
  set expectedPresent(bool v) {
    if (v != _expectedPresent) {
      _expectedPresent = v;
      _changed();
    }
  }

  bool _refreshRemote = false;
  bool get refreshRemote => _refreshRemote;
  set refreshRemote(bool v) {
    if (v != _refreshRemote) {
      _refreshRemote = v;
      _changed();
    }
  }

  bool _awaitingFolderUpload = false;
  bool get awaitingFolderUpload => _awaitingFolderUpload;
  set awaitingFolderUpload(bool v) {
    if (v != _awaitingFolderUpload) {
      _awaitingFolderUpload = v;
      _changed();
    }
  }

  Retention? _override;
  Retention? get override => _override;
  set override(Retention? v) {
    if (v != _override) {
      _override = v;
      _changed();
    }
  }

  String _status = 'queued';
  String get status => _status;
  set status(String v) {
    if (v != _status) {
      _status = v;
      _changed();
    }
  }

  String? _conflict;
  String? get conflict => _conflict;
  set conflict(String? v) {
    if (v != _conflict) {
      _conflict = v;
      _changed();
    }
  }

  String? _remoteCopy;
  String? get remoteCopy => _remoteCopy;
  set remoteCopy(String? v) {
    if (v != _remoteCopy) {
      _remoteCopy = v;
      _changed();
    }
  }

  String? _workingCopy;
  String? get workingCopy => _workingCopy;
  set workingCopy(String? v) {
    if (v != _workingCopy) {
      _workingCopy = v;
      _changed();
    }
  }

  int _size = 0;
  int get size => _size;
  set size(int v) {
    if (v != _size) {
      _size = v;
      _changed();
    }
  }

  late List<String> _preservedCopies = _TrackedStrings(const [], _changed);
  List<String> get preservedCopies => _preservedCopies;
  set preservedCopies(List<String> v) {
    _preservedCopies = _TrackedStrings(v, _changed);
    _changed();
  }

  /// Persistent local index: the stamp, the hash read with it, and when.
  /// Written only from scan results; never inferred from other hashes.
  String? _localStamp;
  String? get localStamp => _localStamp;
  String? _stampHash;
  String? get stampHash => _stampHash;
  int? _stampedAt;
  int? get stampedAt => _stampedAt;
  bool _stampFinal = false;
  bool get stampFinal => _stampFinal;
  void setIndex(String? stamp, String? hash, int? at, [bool isFinal = false]) {
    if (stamp != _localStamp ||
        hash != _stampHash ||
        at != _stampedAt ||
        isFinal != _stampFinal) {
      _localStamp = stamp;
      _stampHash = hash;
      _stampedAt = at;
      _stampFinal = isFinal;
      _changed();
    }
  }

  static const indexKeys = [
    'localStamp',
    'stampHash',
    'stampedAt',
    'stampFinal',
  ];

  /// Content hash the engine recorded for exactly remote version
  /// [remoteHashEtag] when it last uploaded or downloaded that version. Unlike
  /// [baselineHash], it is never rewritten without the matching version.
  String? _remoteHash;
  String? get remoteHash => _remoteHash;
  set remoteHash(String? v) {
    if (v != _remoteHash) {
      _remoteHash = v;
      _changed();
    }
  }

  String? _remoteHashEtag;
  String? get remoteHashEtag => _remoteHashEtag;
  set remoteHashEtag(String? v) {
    if (v != _remoteHashEtag) {
      _remoteHashEtag = v;
      _changed();
    }
  }

  /// Local identity (`volume:inode`, the NTFS file ID on Windows) of the
  /// synchronized item, recorded from scans for a folder, a file with one
  /// link, or a file whose other link a staging record claims (a download);
  /// the engine proves the link count before pairing. A row whose path
  /// vanishes pairs with the item now holding it (spec #33 I1). Null:
  /// unknown or hard-linked by the user, so never paired by identity.
  String? _localIdentity;
  String? get localIdentity => _localIdentity;
  set localIdentity(String? v) {
    if (v != _localIdentity) {
      _localIdentity = v;
      _changed();
    }
  }

  /// A note shown once on the row after the cloud's name won over a local
  /// rename of the same item (spec #33, both sides renamed): "Renamed on
  /// another device to B". Information only; replaced by the row's next
  /// move.
  String? _movedNote;
  String? get movedNote => _movedNote;
  set movedNote(String? v) {
    if (v != _movedNote) {
      _movedNote = v;
      _changed();
    }
  }

  /// A folder's birth time recorded with [localIdentity] ([LocalItem.birth]);
  /// null where the filesystem keeps none (flag SC-074).
  int? _localBirth;
  int? get localBirth => _localBirth;
  set localBirth(int? v) {
    if (v != _localBirth) {
      _localBirth = v;
      _changed();
    }
  }

  /// Listing metadata for Recent and New (spec #24). Written only when a
  /// value changes, like every other field.
  int? _fileId;
  int? get fileId => _fileId;
  set fileId(int? v) {
    if (v != _fileId) {
      _fileId = v;
      _changed();
    }
  }

  /// Cloud modification time, Unix seconds.
  int? _remoteModified;
  int? get remoteModified => _remoteModified;
  set remoteModified(int? v) {
    if (v != _remoteModified) {
      _remoteModified = v;
      _changed();
    }
  }

  /// Gateway-recorded time this file was added to the cloud, Unix seconds.
  int? _addedAt;
  int? get addedAt => _addedAt;
  set addedAt(int? v) {
    if (v != _addedAt) {
      _addedAt = v;
      _changed();
    }
  }

  /// Last listed `oc:permissions` (spec #26); decides View only offline too.
  String? _permissions;
  String? get permissions => _permissions;
  set permissions(String? v) {
    if (v != _permissions) {
      _permissions = v;
      _changed();
    }
  }

  /// This account shares the folder with other household users.
  bool _sharedOut = false;
  bool get sharedOut => _sharedOut;
  set sharedOut(bool v) {
    if (v != _sharedOut) {
      _sharedOut = v;
      _changed();
    }
  }

  /// Gone from this device together with its top folder (`Documents`,
  /// `Music`, `Videos`; spec #34 P7): restored from the cloud, never
  /// inferred as a deletion, until it is back.
  bool _restoring = false;
  bool get restoring => _restoring;
  set restoring(bool v) {
    if (v != _restoring) {
      _restoring = v;
      _changed();
    }
  }

  /// Local modification time from the last scan, Unix seconds. Ranks a
  /// file with an unsynced local edit in Recent.
  int? _localModified;
  int? get localModified => _localModified;
  set localModified(int? v) {
    if (v != _localModified) {
      _localModified = v;
      _changed();
    }
  }

  void recordRemoteVersion(String etag, String hash) {
    remoteHashEtag = etag;
    remoteHash = hash;
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind.name,
    'etag': etag,
    'baselineHash': baselineHash,
    'localHash': localHash,
    'expectedPresent': expectedPresent,
    'refreshRemote': refreshRemote,
    'awaitingFolderUpload': awaitingFolderUpload,
    'override': override?.name,
    'status': status,
    'conflict': conflict,
    'remoteCopy': remoteCopy,
    'workingCopy': workingCopy,
    'size': size,
    'preservedCopies': List<String>.of(preservedCopies),
    'remoteHash': remoteHash,
    'remoteHashEtag': remoteHashEtag,
    'localStamp': _localStamp,
    'stampHash': _stampHash,
    'stampedAt': _stampedAt,
    'stampFinal': _stampFinal,
    // Absent rather than null: rows written before spec #24 stay unchanged
    // until a value arrives.
    if (_fileId != null) 'fileId': _fileId,
    if (_localIdentity != null) 'localIdentity': _localIdentity,
    if (_movedNote != null) 'movedNote': _movedNote,
    if (_localBirth != null) 'localBirth': _localBirth,
    if (_remoteModified != null) 'remoteModified': _remoteModified,
    if (_addedAt != null) 'addedAt': _addedAt,
    if (_localModified != null) 'localModified': _localModified,
    if (_permissions != null) 'permissions': _permissions,
    if (_sharedOut) 'sharedOut': true,
    if (_restoring) 'restoring': true,
  };
  factory Entry.fromJson(Map<String, dynamic> j) =>
      Entry(j['path'] as String, ItemKind.values.byName(j['kind'] as String))
        ..etag = j['etag'] as String?
        ..baselineHash = j['baselineHash'] as String?
        ..localHash = j['localHash'] as String?
        ..expectedPresent = j['expectedPresent'] as bool
        ..refreshRemote = j['refreshRemote'] as bool? ?? false
        ..awaitingFolderUpload = j['awaitingFolderUpload'] as bool? ?? false
        ..override = j['kind'] != 'directory' || j['override'] == null
            ? null
            : Retention.values.byName(j['override'] as String)
        ..status = j['status'] as String
        ..conflict = j['conflict'] as String?
        ..remoteCopy = j['remoteCopy'] as String?
        ..workingCopy = j['workingCopy'] as String?
        ..size = j['size'] as int
        ..preservedCopies = (j['preservedCopies'] as List? ?? []).cast<String>()
        ..remoteHash = j['remoteHash'] as String?
        ..remoteHashEtag = j['remoteHashEtag'] as String?
        ..fileId = j['fileId'] as int?
        ..localIdentity = j['localIdentity'] as String?
        ..movedNote = j['movedNote'] as String?
        ..localBirth = j['localBirth'] as int?
        ..remoteModified = j['remoteModified'] as int?
        ..addedAt = j['addedAt'] as int?
        ..localModified = j['localModified'] as int?
        ..permissions = j['permissions'] as String?
        ..sharedOut = j['sharedOut'] as bool? ?? false
        ..restoring = j['restoring'] as bool? ?? false
        ..setIndex(
          j['localStamp'] as String?,
          j['stampHash'] as String?,
          j['stampedAt'] as int?,
          j['stampFinal'] as bool? ?? false,
        );
}

/// Top-level operation data. Every write marks the operation for the next
/// save. Nested containers cannot report their own writes, so an operation
/// holding one is compared on every save instead (see [Manifest]).
class _TrackedData extends MapBase<String, dynamic> {
  _TrackedData(Map<String, dynamic> values, this._changed)
    : _values = Map<String, dynamic>.of(values);
  final Map<String, dynamic> _values;
  final void Function() _changed;
  @override
  dynamic operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, dynamic value) {
    _values[key] = value;
    _changed();
  }

  @override
  void clear() {
    _values.clear();
    _changed();
  }

  @override
  Iterable<String> get keys => _values.keys;
  @override
  dynamic remove(Object? key) {
    final had = _values.containsKey(key);
    final value = _values.remove(key);
    if (had) _changed();
    return value;
  }

  @override
  bool containsKey(Object? key) => _values.containsKey(key);
  @override
  int get length => _values.length;
}

class Operation {
  Operation(
    this.id,
    this.kind,
    this.path, {
    this._expectedEtag,
    this._phase = 'prepared',
    this._staged,
    this._hash,
  });
  final String id;
  final String kind;
  final String path;
  RowTracker? tracker;
  void _changed() => tracker?.operationChanged(this);
  String? _expectedEtag;
  String? get expectedEtag => _expectedEtag;
  set expectedEtag(String? v) {
    if (v != _expectedEtag) {
      _expectedEtag = v;
      _changed();
    }
  }

  String _phase;
  String get phase => _phase;
  set phase(String v) {
    if (v != _phase) {
      _phase = v;
      _changed();
    }
  }

  String? _staged;
  String? get staged => _staged;
  set staged(String? v) {
    if (v != _staged) {
      _staged = v;
      _changed();
    }
  }

  String? _hash;
  String? get hash => _hash;
  set hash(String? v) {
    if (v != _hash) {
      _hash = v;
      _changed();
    }
  }

  late Map<String, dynamic> _data = _TrackedData(const {}, _changed);
  Map<String, dynamic> get data => _data;
  set data(Map<String, dynamic> v) {
    _data = _TrackedData(v, _changed);
    _changed();
  }

  /// True when [data] holds a nested map or list that may change in place.
  bool get hasNestedData => _data.values.any((v) => v is Map || v is List);
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'path': path,
    'expectedEtag': expectedEtag,
    'phase': phase,
    'staged': staged,
    'hash': hash,
    'data': Map<String, dynamic>.of(data),
  };
  factory Operation.fromJson(Map<String, dynamic> j) => Operation(
    j['id'] as String,
    j['kind'] as String,
    j['path'] as String,
    expectedEtag: j['expectedEtag'] as String?,
    phase: j['phase'] as String,
    staged: j['staged'] as String?,
    hash: j['hash'] as String?,
  )..data = Map<String, dynamic>.from(j['data'] as Map? ?? {});
}

class CloudFailure implements Exception {
  const CloudFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// The status of a file whose upload or download waits for Wi-Fi (Android
/// "Wi-Fi only" on mobile data, decision #108 Q4).
const waitingForWifiStatus = 'waiting for Wi-Fi';

/// A byte transfer refused because the network setting is "Wi-Fi only" and
/// the device is on mobile data (decision #108 Q4; spec #28 R3: only bytes
/// wait). Not a failure: nothing backs off, and the transfer runs when Wi-Fi
/// returns or mobile data is allowed.
class TransfersHeld extends CloudFailure {
  const TransfersHeld()
    : super(
        'Waiting for Wi-Fi. Connect to Wi-Fi, or allow mobile data in the '
        'menu, to transfer files.',
      );
}

/// A short human size for messages: 67108864 -> '64 MB' (binary units,
/// matching the gateway's wording).
String sizeLabel(int bytes) {
  for (final (unit, scale) in const [
    ('GB', 1 << 30),
    ('MB', 1 << 20),
    ('KB', 1 << 10),
  ]) {
    if (bytes >= scale) {
      final value = (bytes / scale * 10).round() / 10;
      final text = value == value.truncateToDouble()
          ? value.toInt().toString()
          : value.toString();
      return '$text $unit';
    }
  }
  return '$bytes bytes';
}

/// The upload size limit of gateways that do not report one (SC-028).
const assumedUploadLimit = 64 * 1024 * 1024;

/// The server refused a file for its size: an HTTP 413, or the local check
/// against the limit the server reported. Never retried automatically.
class UploadTooLarge extends CloudFailure {
  const UploadTooLarge({this.limit, this.size})
    : super('Too large for the server. It stays on this device.', status: 413);
  final int? limit;
  final int? size;

  @override
  String get message => tooLargeMessage(limit);
}

/// Status text of a file the server refused (or, as a best guess, appears
/// to refuse) for its size. These files need attention and are not retried
/// until they change or the user retries.
String tooLargeMessage(int? limit, {bool guess = false}) =>
    '${guess ? 'May be too large' : 'Too large'} for the server'
    '${limit == null ? '' : ' (limit ${sizeLabel(limit)})'}. It stays on this device.';

bool isSizeRefusal(String status) =>
    status.startsWith('Too large for the server') ||
    status.startsWith('May be too large for the server');

/// How an upload failed below the HTTP status level, or with a server error.
enum TransferFailure {
  /// The connection broke while the request was being sent (broken pipe,
  /// reset): what an older gateway's mid-body size refusal looks like.
  write,

  /// The server did not respond in time.
  timeout,

  /// The server answered with a 5xx error.
  server,
}

/// A transfer that did not complete for a reason that may clear by itself.
/// Retried with per-file exponential backoff, never in a hot loop.
class TransferInterrupted extends CloudFailure {
  const TransferInterrupted(super.message, this.kind, {super.status});
  final TransferFailure kind;
}
