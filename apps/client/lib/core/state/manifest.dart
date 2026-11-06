import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../platform/durability.dart';
import '../ports/commit_durability.dart';
import 'identity_index.dart';
import 'model.dart';

/// A row map that attaches change tracking to every row it holds and reports
/// inserts and removals, so saves can write only what changed.
class _RowMap<V> extends MapBase<String, V> {
  _RowMap(this._attach, this._detach);
  final Map<String, V> _values = {};
  final void Function(String key, V value) _attach;
  final void Function(String key, V value) _detach;
  @override
  V? operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, V value) {
    final previous = _values[key];
    _values[key] = value;
    if (previous != null && !identical(previous, value)) {
      _detach(key, previous);
    }
    _attach(key, value);
  }

  @override
  void clear() {
    for (final key in _values.keys.toList()) {
      remove(key);
    }
  }

  @override
  Iterable<String> get keys => _values.keys;
  @override
  Iterable<V> get values => _values.values;
  @override
  bool containsKey(Object? key) => _values.containsKey(key);
  @override
  int get length => _values.length;
  @override
  bool get isEmpty => _values.isEmpty;
  @override
  bool get isNotEmpty => _values.isNotEmpty;
  @override
  V? remove(Object? key) {
    if (!_values.containsKey(key)) return null;
    final value = _values.remove(key) as V;
    _detach(key as String, value);
    return value;
  }
}

/// Persisted sync state. Entries and operations stay in memory; [save] writes
/// only rows whose encoding differs from the last committed encoding, in one
/// transaction, and writes nothing (no transaction) when nothing changed.
class Manifest implements RowTracker {
  /// [durability]: how commits are made durable between commit points
  /// (flag SC-051); the platform's by default (macOS groups commits, every
  /// other platform makes each commit durable). Tests pass a fake, or
  /// [groupCommits] false for a durable commit each time everywhere.
  Manifest(
    this.profile, {
    CommitDurability? durability,
    bool groupCommits = true,
  }) : _durability = groupCommits
           ? durability ?? platformCommitDurability()
           : null {
    profile.createSync(recursive: true);
    _lock = File('${profile.path}/profile.lock')
        .openSync(mode: FileMode.append);
    _lock.lockSync(FileLock.exclusive);
    db = sqlite3.open('${profile.path}/manifest.sqlite');
    // WAL passes every crash-ordering test with synchronous=FULL. A filesystem
    // that cannot host WAL keeps the rollback journal, which is equally safe.
    journalMode =
        db.select('PRAGMA journal_mode=WAL').firstOrNull?.values.first
            as String? ??
        'unknown';
    if (journalMode.toLowerCase() != 'wal') {
      stderr.writeln(
        'anj-cloud manifest: journal_mode is $journalMode, not wal; '
        'continuing with it (crash safety unchanged).',
      );
    }
    db.execute('PRAGMA journal_size_limit=4194304');
    db.execute('PRAGMA synchronous=FULL');
    // Durability mode (spec #31 S2): on macOS fsync does not reach the disk
    // platter, so SQLite syncs with F_FULLFSYNC, including WAL checkpoints.
    // SQLite ignores both where F_FULLFSYNC does not exist (Linux).
    db.execute('PRAGMA fullfsync=ON');
    db.execute('PRAGMA checkpoint_fullfsync=ON');
    // Flag SC-051: with grouped commits SQLite's own sync is a plain fsync;
    // each commit is then ordered by a barrier and every group ends in a
    // full flush (see [commitPoint]). Checkpoints stay F_FULLFSYNC.
    if (_durability != null) db.execute('PRAGMA fullfsync=OFF');
    db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS entries (path TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
    );
    for (final row in db.select('SELECT path, body FROM entries')) {
      final body = row['body'] as String;
      final e = Entry.fromJson(jsonDecode(body) as Map<String, dynamic>);
      entries[e.path] = e;
      _persistedEntries[row['path'] as String] = body;
    }
    for (final row in db.select('SELECT id, body FROM operations')) {
      final body = row['body'] as String;
      final op = Operation.fromJson(jsonDecode(body) as Map<String, dynamic>);
      operations[op.id] = op;
      _persistedOperations[row['id'] as String] = body;
    }
    // Loading is not a change. Rows whose stored key disagrees with their body
    // are rewritten (or removed) by the first save.
    _dirtyEntries.removeWhere(
      (path) => _persistedEntries[path] != null && entries[path] != null,
    );
    _dirtyOperations.removeWhere(
      (id) => _persistedOperations[id] != null && operations[id] != null,
    );
    _dirtyEntries.addAll(
      _persistedEntries.keys.where((path) => !entries.containsKey(path)),
    );
    _dirtyOperations.addAll(
      _persistedOperations.keys.where((id) => !operations.containsKey(id)),
    );
    // Nested data cannot report in-place writes, so loaded operations holding
    // it are re-compared on every save from the start. (Entries have no
    // untracked containers: preservedCopies reports its own writes.)
    _volatileOperations.addAll(
      operations.values.where((op) => op.hasNestedData).map((op) => op.id),
    );
  }

  /// SQLite journal mode in effect (normally `wal`).
  late final String journalMode;
  final Directory profile;
  late final Database db;
  late final RandomAccessFile _lock;
  late final Map<String, Entry> entries = _RowMap<Entry>(
    (path, entry) {
      entry.tracker = this;
      _dirtyEntries.add(path);
      identities.update(path, entry);
    },
    (path, entry) {
      if (identical(entry.tracker, this)) entry.tracker = null;
      _dirtyEntries.add(path);
      identities.update(path, null);
    },
  );

  /// Cloud file ID and local identity of every synchronized row (spec #33),
  /// built as rows load and kept current on every row write.
  final IdentityIndex identities = IdentityIndex();
  late final Map<String, Operation> operations = _RowMap<Operation>(
    (id, op) {
      op.tracker = this;
      _dirtyOperations.add(id);
      _byPath.putIfAbsent(op.path, () => {})[id] = op;
      operationsVersion++;
    },
    (id, op) {
      if (identical(op.tracker, this)) op.tracker = null;
      _dirtyOperations.add(id);
      final bucket = _byPath[op.path];
      if (bucket != null && identical(bucket[id], op)) {
        bucket.remove(id);
        if (bucket.isEmpty) _byPath.remove(op.path);
      }
      operationsVersion++;
    },
  );

  /// Operations by path; serves [operationsAt] (used by the reconcile and
  /// projection paths of spec #13 in place of whole-table scans).
  final Map<String, Map<String, Operation>> _byPath = {};
  final Map<String, String> _persistedEntries = {};
  final Map<String, String> _persistedOperations = {};
  final Set<String> _dirtyEntries = {};
  final Set<String> _dirtyOperations = {};

  /// Operations with nested containers; compared on every save.
  final Set<String> _volatileOperations = {};

  /// Increments whenever any operation is added, removed or changed.
  int operationsVersion = 0;

  /// Write counters (test seam and opt-in metrics).
  int rowsPersisted = 0;
  int transactions = 0;

  /// Grouped commits (flag SC-051), null where every commit is durable.
  CommitDurability? _durability;

  /// A group ends, with a full flush, after this many commits, and at every
  /// [commitPoint] (pass end, settings write, close, and before every
  /// destructive root change, decision #137 (1)).
  static const groupCommits = 64;

  /// Commits since the last full flush (each already ordered by a barrier).
  int unflushedCommits = 0;

  /// Durability calls made (test seam and opt-in metrics), and whether a
  /// failed barrier or flush returned the manifest to durable commits.
  int barriers = 0;
  int flushes = 0;
  bool groupingDisabled = false;

  bool get groupsCommits => _durability != null;

  String get _syncPath {
    final wal = '${profile.path}/manifest.sqlite-wal';
    return File(wal).existsSync() ? wal : '${profile.path}/manifest.sqlite';
  }

  /// After every commit: order it ahead of all later writes, and end the
  /// group when it is full. Never throws: the commit itself succeeded, and
  /// a failed group end is retried at the next commit point.
  void _committed() {
    final durability = _durability;
    if (durability == null) return;
    unflushedCommits++;
    if (unflushedCommits >= groupCommits) {
      try {
        commitPoint();
      } on Object {
        // Still pending: the next commit point flushes or throws.
      }
      return;
    }
    try {
      durability.barrier(_syncPath);
      barriers++;
    } on FileSystemException {
      _disableGrouping();
    }
  }

  /// A commit that is its own commit point (a settings write).
  void _committedDurably() {
    if (_durability == null) return;
    unflushedCommits++;
    commitPoint();
  }

  /// A commit point (decision #129): every commit so far is durable when it
  /// returns, with one full flush, or it throws (and the caller, such as a
  /// destructive root change, does not proceed). The engine calls it at the
  /// end of every pass and before every destructive root change; a settings
  /// write and [close] are commit points too.
  void commitPoint() {
    if (unflushedCommits == 0) return;
    final durability = _durability;
    if (durability != null) {
      try {
        durability.flush(_syncPath);
        flushes++;
        unflushedCommits = 0;
        return;
      } on FileSystemException {
        _disableGrouping();
      }
    }
    // Grouping was refused: a full checkpoint (checkpoint_fullfsync) makes
    // the pending commits durable; later commits are durable each time. A
    // busy checkpoint did not finish: the commits stay pending and the
    // commit point fails (PR #68 review).
    final result = db.select('PRAGMA wal_checkpoint(FULL)');
    final busy = result.isEmpty ? 0 : result.first.values.first as int;
    if (busy != 0) {
      throw const FileSystemException(
        'The manifest checkpoint was busy; its commits are not durable yet.',
      );
    }
    unflushedCommits = 0;
  }

  /// A barrier or flush failed: back to a durable SQLite commit each time.
  /// Pending commits stay counted until a checkpoint makes them durable.
  void _disableGrouping() {
    _durability = null;
    groupingDisabled = true;
    db.execute('PRAGMA fullfsync=ON');
  }

  /// Test builds verify after each save that tracking missed no change.
  bool verifyTracking = true;

  @override
  void entryChanged(Entry entry) {
    _dirtyEntries.add(entry.path);
    identities.update(entry.path, entry);
  }

  @override
  void operationChanged(Operation operation) {
    _dirtyOperations.add(operation.id);
    operationsVersion++;
  }

  /// Operations for one path, in insertion order.
  Iterable<Operation> operationsAt(String path) =>
      _byPath[path]?.values ?? const <Operation>[];

  String? setting(String key) =>
      db.select('SELECT value FROM settings WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void setSetting(String key, String value) {
    if (setting(key) == value) return;
    db.execute('INSERT OR REPLACE INTO settings VALUES (?,?)', [key, value]);
    rowsPersisted++;
    if (db.autocommit) {
      transactions++;
      // Settings (pause, retention) are rare and decisive: a commit point.
      _committedDurably();
    }
  }

  void deleteSetting(String key) {
    if (setting(key) == null) return;
    db.execute('DELETE FROM settings WHERE key=?', [key]);
    rowsPersisted += db.updatedRows;
    if (db.autocommit) {
      transactions++;
      _committedDurably();
    }
  }

  void transaction(void Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      action();
      db.execute('COMMIT');
      transactions++;
      _committed();
    } catch (_) {
      // A failed COMMIT may already have rolled back; keep the original error.
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Compare every row on the next save, repairing any change that reached a
  /// row without passing through tracking. Used at startup and on audits.
  void markAllRows() {
    _dirtyEntries
      ..addAll(entries.keys)
      ..addAll(_persistedEntries.keys);
    _dirtyOperations
      ..addAll(operations.keys)
      ..addAll(_persistedOperations.keys);
  }

  ({Map<String, String?> entries, Map<String, String?> operations}) _pending(
    Iterable<String> entryKeys,
    Iterable<String> operationKeys,
  ) {
    final entryRows = <String, String?>{};
    for (final path in entryKeys) {
      final entry = entries[path];
      final body = entry == null ? null : jsonEncode(entry.toJson());
      if (body != _persistedEntries[path]) entryRows[path] = body;
    }
    final operationRows = <String, String?>{};
    for (final id in operationKeys) {
      final op = operations[id];
      final body = op == null ? null : jsonEncode(op.toJson());
      if (body != _persistedOperations[id]) operationRows[id] = body;
    }
    return (entries: entryRows, operations: operationRows);
  }

  void save({Map<String, String> settings = const {}}) {
    final changed = _pending(_dirtyEntries, {
      ..._dirtyOperations,
      ..._volatileOperations,
    });
    assert(() {
      if (!verifyTracking) return true;
      final full = _pending(
        {...entries.keys, ..._persistedEntries.keys},
        {...operations.keys, ..._persistedOperations.keys},
      );
      if (!full.entries.keys.every(changed.entries.containsKey) ||
          !full.operations.keys.every(changed.operations.containsKey)) {
        throw StateError(
          'Manifest change tracking missed rows: '
          '${full.entries.keys.where((k) => !changed.entries.containsKey(k))} '
          '${full.operations.keys.where((k) => !changed.operations.containsKey(k))}',
        );
      }
      return true;
    }());
    final pendingSettings = {
      for (final setting in settings.entries)
        if (this.setting(setting.key) != setting.value)
          setting.key: setting.value,
    };
    if (changed.entries.isEmpty &&
        changed.operations.isEmpty &&
        pendingSettings.isEmpty) {
      _settle();
      return;
    }
    db.execute('BEGIN IMMEDIATE');
    var rows = 0;
    try {
      for (final setting in pendingSettings.entries) {
        db.execute('INSERT OR REPLACE INTO settings VALUES (?,?)', [
          setting.key,
          setting.value,
        ]);
        rows++;
      }
      for (final row in changed.entries.entries) {
        if (row.value == null) {
          db.execute('DELETE FROM entries WHERE path=?', [row.key]);
        } else {
          db.execute('INSERT OR REPLACE INTO entries VALUES (?,?)', [
            row.key,
            row.value,
          ]);
        }
        rows++;
      }
      for (final row in changed.operations.entries) {
        if (row.value == null) {
          db.execute('DELETE FROM operations WHERE id=?', [row.key]);
        } else {
          db.execute('INSERT OR REPLACE INTO operations VALUES (?,?)', [
            row.key,
            row.value,
          ]);
        }
        rows++;
      }
      db.execute('COMMIT');
    } catch (_) {
      // A failed COMMIT may already have rolled back; keep the original error.
      if (!db.autocommit) db.execute('ROLLBACK');
      // Dirty marks are kept: the next save retries every uncommitted row.
      rethrow;
    }
    rowsPersisted += rows;
    transactions++;
    for (final row in changed.entries.entries) {
      if (row.value == null) {
        _persistedEntries.remove(row.key);
      } else {
        _persistedEntries[row.key] = row.value!;
      }
    }
    for (final row in changed.operations.entries) {
      if (row.value == null) {
        _persistedOperations.remove(row.key);
      } else {
        _persistedOperations[row.key] = row.value!;
      }
    }
    _settle();
    _committed();
  }

  void _settle() {
    for (final id in {..._dirtyOperations, ..._volatileOperations}) {
      final op = operations[id];
      if (op != null && op.hasNestedData) {
        _volatileOperations.add(id);
      } else {
        _volatileOperations.remove(id);
      }
    }
    _dirtyEntries.clear();
    _dirtyOperations.clear();
  }

  void close() {
    commitPoint();
    db.close();
    _lock.unlockSync();
    _lock.closeSync();
  }
}
