import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../ports/documents.dart';

/// One stored approval row, with its folder resolved to a path.
class StoredApproval {
  StoredApproval({
    required this.package,
    required this.folderId,
    required this.folder,
    required this.mode,
    required this.revoked,
    required this.approvedAt,
    this.revokedAt,
    this.lastSeen,
  });
  final String package;
  final int folderId;
  final String folder;
  final AccessMode mode;
  final bool revoked;
  final DateTime approvedAt;
  final DateTime? revokedAt;
  final DateTime? lastSeen;
}

/// The documents provider's own state (spec #28 A5, decision #127), in
/// `<profile>/app-access.sqlite`, beside the manifest and never inside it:
/// the sync engine's schema is unchanged and Linux never creates this file.
/// Only the main isolate opens it; the provider in the runner never does.
///
/// - **documents**: stable document ids. An id is allocated once per path
///   (AUTOINCREMENT, never reused) and follows its item when the provider or
///   the app renames or moves it, so a folder grant follows its folder. Id 0
///   is the AnJ Cloud root.
/// - **approvals**: which app may reach which folder, read or read-write;
///   default none.
/// - **requests**: apps that tried a folder and were refused, so settings
///   can offer to approve them.
/// - **file_users**: apps seen using a single-document grant, by provider
///   document id (spec #28 R1), so "Apps with access" can name them.
class AccessStore {
  AccessStore(Directory profile, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now,
      db = sqlite3.open('${profile.path}/app-access.sqlite') {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL UNIQUE,
        touched INTEGER NOT NULL,
        identity TEXT)''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS approvals (
        package TEXT NOT NULL,
        folder INTEGER NOT NULL,
        mode TEXT NOT NULL CHECK (mode IN ('read', 'write')),
        revoked INTEGER NOT NULL DEFAULT 0,
        approved_at INTEGER NOT NULL,
        revoked_at INTEGER,
        last_seen INTEGER,
        PRIMARY KEY (package, folder))''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS file_users (
        document TEXT NOT NULL,
        package TEXT NOT NULL,
        last_seen INTEGER NOT NULL,
        PRIMARY KEY (document, package))''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS requests (
        package TEXT NOT NULL,
        folder INTEGER NOT NULL,
        at INTEGER NOT NULL,
        PRIMARY KEY (package, folder))''');
  }

  final Database db;
  final DateTime Function() clock;
  int get _now => clock().millisecondsSinceEpoch;

  /// The stable id of [path] ('' is the root, 0), allocated on first use.
  int idFor(String path) {
    if (path.isEmpty) return 0;
    final found = db.select('SELECT id FROM documents WHERE path = ?', [path]);
    if (found.isNotEmpty) return found.first['id'] as int;
    db.execute('INSERT INTO documents (path, touched) VALUES (?, ?)', [
      path,
      _now,
    ]);
    return db.lastInsertRowId;
  }

  /// Ids for many paths in one transaction.
  Map<String, int> idsFor(Iterable<String> paths) {
    final result = <String, int>{};
    db.execute('BEGIN');
    try {
      for (final path in paths) {
        result[path] = idFor(path);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return result;
  }

  /// The path of document [id], or null when it no longer exists.
  String? pathOf(int id) {
    if (id == 0) return '';
    final found = db.select('SELECT path FROM documents WHERE id = ?', [id]);
    return found.isEmpty ? null : found.first['path'] as String;
  }

  /// The local identity [id]'s folder had when an approval first saw it.
  String? identityOf(int id) {
    final found = db.select('SELECT identity FROM documents WHERE id = ?', [
      id,
    ]);
    return found.isEmpty ? null : found.first['identity'] as String?;
  }

  void bindIdentity(int id, String identity) => db.execute(
    'UPDATE documents SET identity = ? WHERE id = ?',
    [identity, id],
  );

  /// [from] (and everything beneath it) is now at [to]: ids follow. A stale
  /// id already recorded at the destination is dropped, so it can never be
  /// inherited by the moved item.
  void move(String from, String to) {
    db.execute('BEGIN');
    try {
      _drop(to);
      db.execute(
        'UPDATE documents SET path = ? || substr(path, ?), touched = ? '
        "WHERE path = ? OR substr(path, 1, ?) = ? || '/'",
        [to, from.length + 1, _now, from, from.length + 1, from],
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// [path] and everything beneath it are gone: their ids, approvals and
  /// requests are removed. Returns the approvals that ended.
  List<StoredApproval> forget(String path) {
    final ended = approvals().where((a) => _within(a.folder, path)).toList();
    db.execute('BEGIN');
    try {
      _drop(path);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return ended;
  }

  void _drop(String path) {
    final ids = [
      for (final row in db.select(
        "SELECT id FROM documents WHERE path = ? OR substr(path, 1, ?) = ? || '/'",
        [path, path.length + 1, path],
      ))
        row['id'] as int,
    ];
    for (final id in ids) {
      db.execute('DELETE FROM approvals WHERE folder = ?', [id]);
      db.execute('DELETE FROM requests WHERE folder = ?', [id]);
      db.execute('DELETE FROM documents WHERE id = ?', [id]);
    }
  }

  /// Drops ids whose path is not in [present] and was not allocated or moved
  /// within [grace] (a rename shows in the projection one pass later).
  /// Returns the approvals that ended with them.
  List<StoredApproval> prune(Set<String> present, {required Duration grace}) {
    final cutoff = _now - grace.inMilliseconds;
    final stale = [
      for (final row in db.select(
        'SELECT path FROM documents WHERE touched < ?',
        [cutoff],
      ))
        if (!present.contains(row['path'] as String)) row['path'] as String,
    ];
    final ended = <StoredApproval>[];
    for (final path in stale) {
      if (db.select('SELECT 1 FROM documents WHERE path = ?', [path]).isEmpty) {
        continue; // already dropped beneath a stale ancestor
      }
      ended.addAll(forget(path));
    }
    return ended;
  }

  static bool _within(String path, String folder) =>
      path == folder || path.startsWith('$folder/');

  List<StoredApproval> approvals() => [
    for (final row in db.select(
      'SELECT a.*, d.path FROM approvals a LEFT JOIN documents d ON d.id = a.folder '
      'ORDER BY a.package, d.path',
    ))
      if (row['folder'] == 0 || row['path'] != null)
        StoredApproval(
          package: row['package'] as String,
          folderId: row['folder'] as int,
          folder: row['folder'] == 0 ? '' : row['path'] as String,
          mode: AccessMode.values.byName(row['mode'] as String),
          revoked: row['revoked'] == 1,
          approvedAt: DateTime.fromMillisecondsSinceEpoch(
            row['approved_at'] as int,
          ),
          revokedAt: _time(row['revoked_at']),
          lastSeen: _time(row['last_seen']),
        ),
  ];

  static DateTime? _time(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

  /// Approves (or approves again) [package] for [folder]; a fresh approval
  /// starts not connected.
  void approve(String package, String folder, AccessMode mode) {
    final id = idFor(folder);
    db.execute(
      'INSERT INTO approvals (package, folder, mode, revoked, approved_at) '
      'VALUES (?, ?, ?, 0, ?) ON CONFLICT (package, folder) DO UPDATE SET '
      'mode = excluded.mode, revoked = 0, approved_at = excluded.approved_at, '
      'revoked_at = NULL, last_seen = NULL',
      [package, id, mode.name, _now],
    );
    db.execute('DELETE FROM requests WHERE package = ? AND folder = ?', [
      package,
      id,
    ]);
  }

  void revoke(String package, String folder) {
    db.execute(
      'UPDATE approvals SET revoked = 1, revoked_at = ? '
      'WHERE package = ? AND folder = ? AND revoked = 0',
      [_now, package, idFor(folder)],
    );
  }

  /// Removes [package]'s row and request for [folder].
  void remove(String package, String folder) {
    final id = idFor(folder);
    db.execute('DELETE FROM approvals WHERE package = ? AND folder = ?', [
      package,
      id,
    ]);
    db.execute('DELETE FROM requests WHERE package = ? AND folder = ?', [
      package,
      id,
    ]);
  }

  void seen(String package, int folderId, DateTime at) {
    db.execute(
      'UPDATE approvals SET last_seen = ? WHERE package = ? AND folder = ? '
      'AND revoked = 0',
      [at.millisecondsSinceEpoch, package, folderId],
    );
  }

  void request(String package, String folder) {
    db.execute(
      'INSERT INTO requests (package, folder, at) VALUES (?, ?, ?) '
      'ON CONFLICT (package, folder) DO UPDATE SET at = excluded.at',
      [package, idFor(folder), _now],
    );
  }

  List<AccessRequest> requests() => [
    for (final row in db.select(
      'SELECT r.package, r.folder, r.at, d.path FROM requests r '
      'LEFT JOIN documents d ON d.id = r.folder ORDER BY r.at DESC',
    ))
      if (row['folder'] == 0 || row['path'] != null)
        AccessRequest(
          row['package'] as String,
          row['folder'] == 0 ? '' : row['path'] as String,
          DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
        ),
  ];

  /// [package] used its grant on the single document [documentId].
  void fileUsed(String documentId, String package, DateTime at) => db.execute(
    'INSERT INTO file_users (document, package, last_seen) VALUES (?, ?, ?) '
    'ON CONFLICT (document, package) DO UPDATE SET last_seen = excluded.last_seen',
    [documentId, package, at.millisecondsSinceEpoch],
  );

  /// The apps seen using each single-document grant, by document id.
  Map<String, List<String>> fileUsers() {
    final users = <String, List<String>>{};
    for (final row in db.select(
      'SELECT document, package FROM file_users ORDER BY document, package',
    )) {
      (users[row['document'] as String] ??= []).add(row['package'] as String);
    }
    return users;
  }

  void forgetFileUsers(String documentId) =>
      db.execute('DELETE FROM file_users WHERE document = ?', [documentId]);

  void close() => db.close();
}
