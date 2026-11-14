import 'dart:io';

import 'package:crypto/crypto.dart';

import 'artifacts.dart';
import '../ports/release_guard.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';

enum ReleaseOutcome {
  /// Bytes were verified under the guard, unlinked and their records removed.
  released,

  /// Verified content is not the expected redundant version; it is kept.
  differs,

  /// The guard was refused or broke (open, changing or racing); retried later.
  busy,

  /// Ownership, identity or link count is not explained; kept as uncertain.
  uncertain,
}

/// Releases staging copies the server provably holds (decision #37), using the
/// same guarded primitive as eviction: an exclusive lease with identity, stamp
/// and link-count checks, a hash taken through that descriptor, then unlink
/// under the still-valid lease. Never touches the synchronized root.
class StagingRelease {
  StagingRelease(this.manifest, this.tree, this.artifacts);
  final Manifest manifest;
  final RootTree tree;
  final Artifacts artifacts;

  /// Synchronous test hook at exact crash/order boundaries; absent in the app.
  void Function(String point, Operation record, int fd)? barrier;

  /// Roles whose (hash, version) pair was recorded from an upload the server
  /// acknowledged or from a download of exactly that version. Local snapshots
  /// such as `check` or `working` carry the entry version but local bytes.
  static const versionRoles = {
    'upload',
    'upload-recovery',
    'download',
    'conflict',
    'eviction-proof',
    'finish-proof',
    'working-upload',
  };

  /// Pending work that may still own or enumerate this path's staging records.
  static const busyKinds = {
    'upload',
    'delete',
    'preserve',
    'evict',
    'working',
    'finish-editing',
  };

  static String entryPath(Operation record) =>
      (record.data['entryPath'] ?? record.path) as String;

  bool busy(String path) => manifest.operations.values.any(
    (o) => o.path == path && busyKinds.contains(o.kind),
  );

  /// The hash recorded for exactly [etag], or null when it is unknown or the
  /// recorded evidence disagrees. Unknown always means retain.
  String? hashForVersion(Entry entry, String etag) {
    if (entry.remoteHashEtag == etag && entry.remoteHash != null) {
      return entry.remoteHash;
    }
    final hashes = artifacts.records
        .where(
          (o) =>
              entryPath(o) == entry.path &&
              o.phase == 'complete' &&
              versionRoles.contains(o.data['role']) &&
              o.expectedEtag == etag &&
              o.data['versionReadBack'] != true &&
              o.hash != null,
        )
        .map((o) => o.hash!)
        .toSet();
    return hashes.length == 1 ? hashes.single : null;
  }

  NativeFileInfo? info(String name) {
    try {
      return artifacts.native.info(tree.stageFd, name);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  /// A crash between unlink and record removal leaves a record whose verified
  /// release intent is durable but whose bytes are gone; finish it. A record
  /// whose bytes are still present keeps its intent only while those bytes
  /// still match it (the ordinary release re-verifies them under the guard);
  /// otherwise the stale intent is cleared and the copy stays retained.
  /// Paths with pending work are left alone.
  void recoverInterrupted() {
    final finished = <Operation>[];
    var cleared = false;
    for (final record in artifacts.records.toList()) {
      final intent = record.data['releasing'];
      if (intent == null) continue;
      if (tree.phonePaused(
        path: record.path,
        staged: record.data['name'] as String?,
      )) {
        continue;
      }
      if (busy(entryPath(record)) || busy(record.path)) continue;
      if (record.data['directoryIdentity'] !=
          tree.native.identity(tree.stageFd)) {
        continue;
      }
      final current = info(record.data['name'] as String);
      if (current == null) {
        finished.add(record);
      } else if (current.identity != record.data['identity'] ||
          _hash(artifacts.resolve(record.staged!)) != intent) {
        record.data.remove('releasing');
        cleared = true;
      }
    }
    if (cleared) manifest.save();
    if (finished.isNotEmpty) _finalize(finished);
  }

  String _hash(File file) {
    final digest = _DigestSink();
    final sink = sha256.startChunkedConversion(digest);
    final handle = file.openSync();
    var total = 0;
    try {
      while (true) {
        final chunk = handle.readSync(1024 * 1024);
        if (chunk.isEmpty) break;
        total += chunk.length;
        sink.add(chunk);
      }
    } finally {
      handle.closeSync();
      tree.native.meter.record('staging-release', total);
    }
    sink.close();
    return digest.value!;
  }

  /// [aliases] are other owned names for the same inode (hard links made by
  /// `installOwned`); they are released together or not at all.
  ReleaseOutcome release(
    Operation record,
    String expectedHash, {
    List<Operation> aliases = const [],
  }) {
    final native = artifacts.native;
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
    final stageIdentity = tree.native.identity(tree.stageFd);
    final all = [record, ...aliases];
    if (all.any(
      (o) =>
          o.kind != 'artifact' ||
          o.phase != 'complete' ||
          o.staged == null ||
          o.data['identity'] == null ||
          o.data['directoryIdentity'] != stageIdentity,
    )) {
      return ReleaseOutcome.uncertain;
    }
    final name = record.data['name'] as String;
    final current = info(name);
    if (current == null || current.identity != record.data['identity']) {
      return ReleaseOutcome.uncertain;
    }
    for (final alias in aliases) {
      final held = info(alias.data['name'] as String);
      if (held == null ||
          held.identity != current.identity ||
          alias.data['identity'] != current.identity) {
        return ReleaseOutcome.uncertain;
      }
    }
    // Any link this profile cannot account for (including a root path) keeps
    // the bytes; the guard enforces the same count atomically below.
    if (current.links != all.length) return ReleaseOutcome.uncertain;
    final int fd;
    try {
      fd = native.guard(tree.stageFd, name, current, links: all.length);
    } on FileSystemException {
      return ReleaseOutcome.busy;
    }
    try {
      if (native.hash(fd, purpose: 'staging-release') != expectedHash) {
        _clearIntent(all);
        return ReleaseOutcome.differs;
      }
      // Durable intent precedes unlink; removal is persisted only afterwards.
      for (final o in all) {
        o.data['releasing'] = expectedHash;
      }
      manifest.save();
      barrier?.call('before-unlink', record, fd);
      for (final alias in aliases) {
        native.valid(fd);
        native.unlink(fd, tree.stageFd, alias.data['name'] as String);
      }
      native.valid(fd);
      native.unlink(fd, tree.stageFd, name);
      barrier?.call('after-unlink-before-db', record, fd);
    } on FileSystemException {
      return ReleaseOutcome.busy;
    } finally {
      native.close(fd);
    }
    _finalize(all);
    return ReleaseOutcome.released;
  }

  void _clearIntent(List<Operation> records) {
    if (records.any((o) => o.data.containsKey('releasing'))) {
      for (final o in records) {
        o.data.remove('releasing');
      }
      manifest.save();
    }
  }

  void _finalize(List<Operation> released) {
    for (final record in released) {
      manifest.operations.remove(record.id);
      final staged = record.staged;
      manifest.operations.removeWhere(
        (_, o) => o.kind == 'retained' && o.staged == staged,
      );
      manifest.entries[entryPath(record)]?.preservedCopies.remove(staged);
      manifest.entries[record.path]?.preservedCopies.remove(staged);
    }
    manifest.save();
  }
}

class _DigestSink implements Sink<Digest> {
  String? value;
  @override
  void add(Digest digest) {
    value = digest.toString();
  }

  @override
  void close() {}
}
