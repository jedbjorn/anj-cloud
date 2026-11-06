import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../state/manifest.dart';
import '../state/model.dart';
import 'root_tree.dart';

/// How the persisted `rootIdentity` related to the root opened at start.
enum RootOutcome {
  /// The stored identity names this root (possibly re-recorded, e.g. with a
  /// birth time the stored value lacked).
  matched,

  /// A pre-fix `st_dev:st_ino` value whose device still matches: accepted
  /// exactly as before the fix and rewritten in the stable form.
  upgraded,

  /// A pre-fix value whose device number changed (btrfs after a reboot),
  /// accepted on positive evidence that this is the same tree.
  migrated,

  /// Not accepted: the worker stays paused exactly as before.
  refused,
}

typedef RootAcceptance = ({RootOutcome outcome, String detail});

final _legacyIdentity = RegExp(r'^(\d+):(\d+)$');
final _legacyStamp = RegExp(r'^(\d+):(\d+):(\d+):(\d+):(\d+)$');

/// True when [stored] and [current] (both `volume:ino[:b<birth>]`) name the
/// same directory. Device-number keys compare exactly, as before. On a stable
/// fsid key the birth time is compared when both sides carry it; a value
/// recorded where the filesystem reported none still matches on volume+inode.
bool sameRootIdentity(String stored, String current) {
  if (stored == current) return true;
  final a = stored.split(':');
  final b = current.split(':');
  if (a.length < 2 || a.length > 3 || b.length < 2 || b.length > 3) {
    return false;
  }
  if (a[0] != b[0] || a[1] != b[1] || !a[0].startsWith('f')) return false;
  return a.length == 2 || b.length == 2 || a[2] == b[2];
}

/// Checks the persisted root identity against [tree] (opened from the
/// `root` setting) and, when the root is accepted, records the stable form.
///
/// A legacy `st_dev:st_ino` value is accepted without further evidence only
/// when its device still matches (the pre-fix rule). When only the device
/// differs it is accepted only on the evidence of [evaluateLegacyRoot]
/// (decision #54); see there for the rule and why it cannot lead to blind
/// remote deletions or overwrites. Every other mismatch is refused and
/// nothing is written. [onLongCheck] is called once, before the first file
/// content is read for evidence (startup can then take as long as that read).
RootAcceptance acceptRoot(
  Manifest manifest,
  RootTree tree, {
  void Function()? onLongCheck,
}) {
  final stored = manifest.setting('rootIdentity');
  final rootSetting = manifest.setting('root');
  if (stored == null || rootSetting == null) {
    return (outcome: RootOutcome.refused, detail: 'no stored root identity');
  }
  final info = tree.native.rootInfo(tree.fd);
  if (sameRootIdentity(stored, info.identity)) {
    if (stored != info.identity) {
      manifest.setSetting('rootIdentity', info.identity);
    }
    return (outcome: RootOutcome.matched, detail: info.identity);
  }
  final legacy = _legacyIdentity.firstMatch(stored);
  if (legacy == null) {
    return (outcome: RootOutcome.refused, detail: 'identity changed');
  }
  if (!info.stable) {
    // The current key is still a device number: nothing would be gained and
    // the previous behaviour (stay paused) is kept exactly.
    return (
      outcome: RootOutcome.refused,
      detail: 'legacy identity on a filesystem without a stable fsid',
    );
  }
  final current = _legacyIdentity.firstMatch(info.legacy)!;
  if (legacy.group(2) != current.group(2)) {
    return (outcome: RootOutcome.refused, detail: 'root inode changed');
  }
  if (tree.root.path != rootSetting ||
      Directory(rootSetting).resolveSymbolicLinksSync() != rootSetting) {
    return (outcome: RootOutcome.refused, detail: 'root path changed');
  }
  final legacyDevice = legacy.group(1)!;
  final volume = info.identity.split(':').first;
  if (legacyDevice == current.group(1)) {
    _translate(manifest, legacyDevice, volume);
    manifest.save(settings: {'rootIdentity': info.identity});
    return (outcome: RootOutcome.upgraded, detail: info.identity);
  }
  final evidence = evaluateLegacyRoot(
    manifest,
    tree,
    legacyDevice,
    volume,
    onLongCheck: onLongCheck,
  );
  if (!evidence.accepted) {
    return (outcome: RootOutcome.refused, detail: evidence.detail);
  }
  _translate(manifest, legacyDevice, volume);
  // One transaction: translated rows and the new identity land together, so
  // an interrupted migration leaves the legacy state to be evaluated again.
  manifest.save(settings: {'rootIdentity': info.identity});
  return (outcome: RootOutcome.migrated, detail: evidence.detail);
}

typedef LegacyEvidence = ({
  bool accepted,
  String detail,
  int inodeProven,
  int contentProven,
  int forward,
  int reference,
});

/// Evidence that a root whose device number changed (btrfs after a reboot)
/// is the tree the manifest last observed, allowing ordinary use made since
/// then (decision #54). Read-only: one stat scan, plus a content hash only
/// for files whose stamp cannot decide.
///
/// R (the reference time) is the latest moment the client is known to have
/// observed the tree: the maximum over entries of the recorded stamp ctime
/// and the time the stamp was taken (`stampedAt`). Every ctime the kernel
/// sets is "now", so a change made after R carries a ctime after R, while a
/// rolled-back snapshot (or block image) carries only ctimes from before it
/// was taken. The rule therefore accepts forward-in-time changes and refuses
/// any discrepancy whose evidence predates R:
///
/// * an expected file present with its recorded inode and full stamp is
///   inode-proven; with the same inode but a ctime BELOW the recorded one,
///   time went backwards: refuse (rollback);
/// * an expected file that changed (other stamp or inode, e.g. an atomic save)
///   is accepted if its ctime is after R; otherwise its bytes must still hash
///   to the recorded local hash, or refuse;
/// * an expected entry that is missing (deleted or renamed away) is accepted
///   if its nearest existing ancestor directory's ctime is after R (unlink and
///   rename update the parent's ctime); otherwise refuse;
/// * an expected entry whose kind changed is judged by the new item's ctime;
/// * an item at a path the manifest does not expect present (deleted, evicted
///   or cloud-only, e.g. a `.~lock` file recreated at a tombstone) is accepted
///   if its ctime is after R; otherwise refuse;
/// * paths unknown to the manifest are ignored (they upload create-only);
/// * at least one file must be inode-proven (the same filesystem directory,
///   not an equal copy).
///
/// Why no remote content is lost: acceptance only rewrites identity prefixes;
/// the engine then runs its normal start path, the same as a start after
/// offline edits under a matching identity. Changed files fail the stamp
/// match, are re-read and upload with `If-Match` on the baseline etag (a
/// conflict, keeping both, if the remote moved); missing entries become
/// "delete queued" and delete only with `If-Match` on the recorded etag;
/// unknown paths upload with `If-None-Match: *`. What the pause guards
/// against - a stale tree inferring deletions of newer files - always shows
/// evidence older than R and is refused.
///
/// Residual (documented, not detected): on ext4 the volume key is the folded
/// superblock UUID, so a block-level clone (dd image, restored LVM snapshot)
/// mounted at the same path matches volume, inode and birth time and passes
/// the ordinary stable-identity check without reaching this function; a
/// stale clone can then queue If-Match deletions of files created after it.
LegacyEvidence evaluateLegacyRoot(
  Manifest manifest,
  RootTree tree,
  String legacyDevice,
  String volume, {
  void Function()? onLongCheck,
}) {
  var inodeProven = 0;
  var contentProven = 0;
  var forward = 0;
  var reference = 0;
  LegacyEvidence result(bool accepted, String detail) => (
    accepted: accepted,
    detail: detail,
    inodeProven: inodeProven,
    contentProven: contentProven,
    forward: forward,
    reference: reference,
  );
  for (final entry in manifest.entries.values) {
    final recorded = _legacyStamp.firstMatch(entry.localStamp ?? '');
    if (recorded != null) {
      reference = max(reference, int.parse(recorded.group(5)!));
    }
    final at = entry.stampedAt;
    if (at != null) reference = max(reference, at * 1000);
  }
  final Map<String, LocalItem> local;
  final int rootCtime;
  try {
    local = tree.scanItems(includeExcluded: true);
    rootCtime = int.parse(tree.native.stamp(tree.fd).split(':')[4]);
  } on FileSystemException catch (error) {
    return result(false, 'root scan failed: ${error.message}');
  }
  int ctime(LocalItem item) => int.parse(item.scanStamp!.split(':')[4]);
  int ancestorCtime(String path) {
    var parent = p.posix.dirname(path);
    while (parent != '.') {
      final item = local[parent];
      if (item != null) return ctime(item);
      parent = p.posix.dirname(parent);
    }
    return rootCtime;
  }

  final hashes = <Entry>[];
  for (final entry in manifest.entries.values) {
    final item = local[entry.path];
    if (!entry.expectedPresent) {
      if (item == null) continue;
      if (ctime(item) > reference) {
        forward++;
        continue;
      }
      return result(false, 'older item at not-expected ${entry.path}');
    }
    if (item == null) {
      if (ancestorCtime(entry.path) > reference) {
        forward++;
        continue;
      }
      return result(false, 'missing ${entry.path} before the last pass');
    }
    if (item.kind != entry.kind) {
      if (ctime(item) > reference) {
        forward++;
        continue;
      }
      return result(false, 'kind changed at ${entry.path} before last pass');
    }
    if (entry.kind != ItemKind.file) continue;
    final recorded = _legacyStamp.firstMatch(entry.localStamp ?? '');
    final now = item.scanStamp!.split(':');
    final sameInode =
        recorded != null &&
        recorded.group(1) == legacyDevice &&
        now[0] == volume &&
        now[1] == recorded.group(2);
    if (sameInode && ctime(item) < int.parse(recorded.group(5)!)) {
      return result(false, 'ctime of ${entry.path} went backwards');
    }
    if (sameInode &&
        entry.stampHash != null &&
        entry.stampHash == entry.localHash &&
        now[2] == recorded.group(3) &&
        now[3] == recorded.group(4) &&
        now[4] == recorded.group(5)) {
      inodeProven++;
      continue;
    }
    if (ctime(item) > reference) {
      forward++;
      continue;
    }
    hashes.add(entry);
  }
  if (inodeProven == 0) {
    return result(false, 'no file proves the same filesystem directory');
  }
  if (hashes.isNotEmpty) onLongCheck?.call();
  for (final entry in hashes) {
    final String hash;
    try {
      hash = tree.native.copyAndHash(
        tree.fd,
        entry.path,
        null,
        purpose: 'root-migration',
      );
    } on FileSystemException catch (error) {
      return result(false, 'cannot read ${entry.path}: ${error.message}');
    }
    if (entry.localHash == null || hash != entry.localHash) {
      return result(false, 'bytes of ${entry.path} changed before last pass');
    }
    contentProven++;
  }
  return result(
    true,
    'same tree: $inodeProven inode-proven, $contentProven content-proven, '
    '$forward changed after the last pass',
  );
}

/// Rewrites persisted values recorded with the legacy root device so they use
/// the stable volume key. Sound because the worker only ever ran while the
/// root's device equalled [legacyDevice], and the caller has established that
/// the current root is that same filesystem; values on any other device
/// (nested mounts, a staging directory elsewhere) are left unchanged and are
/// simply not trusted again (a stamp re-reads once; a journal identity is
/// treated as changed, as after any reboot before this fix).
void _translate(Manifest manifest, String legacyDevice, String volume) {
  final prefix = '$legacyDevice:';
  String? convert(String value) =>
      value.startsWith(prefix) && RegExp(r'^\d+(:\d+)+$').hasMatch(value)
      ? '$volume:${value.substring(prefix.length)}'
      : null;
  for (final entry in manifest.entries.values) {
    final stamp = entry.localStamp;
    final next = stamp == null ? null : convert(stamp);
    if (next != null) {
      entry.setIndex(next, entry.stampHash, entry.stampedAt, entry.stampFinal);
    }
  }
  bool identityKey(String key) {
    final lower = key.toLowerCase();
    return lower.contains('identity') || lower.contains('stamp');
  }

  var changed = false;
  Object? walk(Object? value, bool keyed) {
    if (value is String) {
      final next = keyed ? convert(value) : null;
      if (next == null) return value;
      changed = true;
      return next;
    }
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key: walk(e.value, keyed || identityKey('${e.key}')),
      };
    }
    if (value is List) return [for (final v in value) walk(v, keyed)];
    return value;
  }

  for (final op in manifest.operations.values) {
    changed = false;
    final next = walk(op.data, false) as Map;
    if (changed) op.data = Map<String, dynamic>.from(next);
  }
}
