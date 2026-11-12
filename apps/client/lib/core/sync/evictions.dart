import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import '../gateway/cloud_api.dart';
import '../ports/release_guard.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import 'recovery_copies.dart';
import '../local/root_tree.dart';

/// No network awaits occur after the first lease is acquired. Test barriers are
/// synchronous and absent in the application; they exercise exact crash/order
/// boundaries without adding operator authority to the product.
class Evictions {
  Evictions(this.manifest, this.tree, this.cloud, this.artifacts);
  final Manifest manifest;
  final RootTree tree;
  final CloudApi cloud;
  final Artifacts artifacts;
  void Function(String, Operation, int)? barrier;
  String get binding =>
      '${manifest.profile.resolveSymbolicLinksSync()}|${manifest.setting('accountOrigin') ?? ''}|${manifest.setting('accountUid') ?? ''}';
  void rootCurrent() => tree.native.checkRoot(tree.fd, tree.root.path);
  Future<String> hash(File file) =>
      tree.native.meter.hashFile(file, 'eviction');
  NativeFileInfo? info(String path) {
    try {
      return artifacts.native.info(tree.stageFd, p.basename(path));
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) {
        return null;
      }
      rethrow;
    }
  }

  bool proof(Operation op) =>
      op.hash != null &&
      op.expectedEtag != null &&
      op.data['provenHash'] == op.hash &&
      op.data['provenEtag'] == op.expectedEtag &&
      op.data['binding'] == binding;
  void removeMissingArtifacts(Operation op) {
    for (final id in (op.data['artifacts'] as List? ?? []).cast<String>()) {
      final record = manifest.operations[id];
      if (record != null &&
          record.staged != null &&
          info(record.staged!) == null) {
        manifest.operations.remove(id);
      }
    }
    final target = artifacts.record(File(op.staged!));
    if (target != null && info(op.staged!) == null) {
      manifest.operations.remove(target.id);
    }
  }

  void complete(Operation op, Entry entry, bool rootPresent) {
    entry.expectedPresent = rootPresent;
    entry.status = rootPresent ? 'local replacement retained' : 'cloud-only';
    if (!rootPresent) {
      entry.localHash = null;
    }
    removeMissingArtifacts(op);
    manifest.operations.remove(op.id);
    manifest.save();
  }

  void retain(Operation op, Entry entry, String reason) {
    if (op.staged != null && info(op.staged!) != null) {
      if (!entry.preservedCopies.contains(op.staged)) {
        entry.preservedCopies.add(op.staged!);
      }
      final record = Operation(
        uniqueId(),
        'retained',
        entry.path,
        staged: op.staged,
        hash: op.hash,
        expectedEtag: op.expectedEtag,
      );
      manifest.operations[record.id] = record;
    }
    entry.conflict = reason;
    entry.status = 'conflict';
    manifest.operations.remove(op.id);
    manifest.save();
  }

  void recover(
    Map<String, LocalItem> local, {
    required bool Function(String) cloudWanted,
  }) {
    for (final op
        in manifest.operations.values
            .where((o) => o.kind == 'evict')
            .toList()) {
      final entry = manifest.entries[op.path];
      if (entry == null) {
        continue;
      }
      if (op.staged == null) {
        if (!cloudWanted(op.path)) {
          manifest.operations.remove(op.id);
          manifest.save();
        }
        continue;
      }
      final held = info(op.staged!);
      final here = local.containsKey(op.path);
      if (op.data['binding'] != null && op.data['binding'] != binding) {
        entry.status = 'Cloud pending: profile/account binding changed.';
        entry.expectedPresent = here;
        continue;
      }
      if (held != null && (op.data['identity'] != held.identity)) {
        entry.status = 'Cloud pending: quarantine identity changed; recovery bytes retained.';
        entry.expectedPresent = here;
        continue;
      }
      if (!cloudWanted(op.path)) {
        if (held != null && !here) {
          rootCurrent();
          artifacts.native.install(
            tree.fd,
            op.path,
            tree.stageFd,
            p.basename(op.staged!),
          );
          entry.expectedPresent = true;
          // The restored file as it now stands (identity and stamp), with
          // the guarded hash of its bytes; unknown stamp means "read again".
          final restored = tree.statItem(op.path);
          local[op.path] = LocalItem(
            op.path,
            entry.kind,
            hash: op.hash,
            size: restored?.size ?? held.size,
            identity: restored?.identity,
            links: restored?.links,
            scanStamp: restored?.scanStamp,
          );
          tree.own(op.path);
        } else if (held != null && here) {
          retain(op, entry, replacementRetainedConflict);
          continue;
        }
        manifest.operations.remove(op.id);
        manifest.save();
        continue;
      }
      if (op.phase == 'reclaiming' && held == null && proof(op)) {
        // The persisted proof and reclaim intent, not absence itself, establish
        // the completed local effect. A replacement root is never removed.
        complete(op, entry, here);
        continue;
      }
      if (held != null) {
        entry.expectedPresent = here;
        if (here) {
          retain(op, entry, rootReplacedConflict);
        }
      } else if ((op.phase == 'prepared' || op.phase == 'proved') && !here) {
        // We never began a local rename, so ordinary external deletion still
        // has its normal meaning. Do not mask it as an eviction.
        manifest.operations.remove(op.id);
        manifest.save();
      } else if (op.phase == 'quarantining' ||
          op.phase == 'quarantined' ||
          op.phase == 'reclaiming') {
        entry.expectedPresent = here;
        entry.status =
            'Cloud pending: interrupted local effect needs recovery.';
      }
    }
  }

  Future<void> run(Entry entry) async {
    rootCurrent();
    Operation? existing = manifest.operations.values
        .where((o) => o.kind == 'evict' && o.path == entry.path)
        .firstOrNull;
    if (entry.conflict != null) {
      return;
    }
    if (existing?.data['binding'] != null &&
        existing!.data['binding'] != binding) {
      entry.status =
          'Cloud pending: original account/profile binding is unavailable.';
      return;
    }
    if (existing?.staged != null &&
        info(existing!.staged!) != null &&
        proof(existing)) {
      if (await hash(artifacts.resolve(existing.staged!)) != existing.hash) {
        retain(existing, entry, quarantineChangedConflict);
        return;
      }
    }
    final working = manifest.operations.values
        .where((o) => o.path == entry.path && o.kind == 'working')
        .toList();
    if (working.isNotEmpty) {
      // Decision #183: only an edited copy pins the row as an edit; an
      // unchanged one waits, status untouched, for its reclamation.
      if (working.any(artifacts.workingEdited)) {
        entry.status = 'Cloud pending: editor working copies stay pinned in this prototype.';
      }
      return;
    }
    if (manifest.operations.values.any(
      (o) =>
          o.path == entry.path &&
          ['upload', 'delete', 'preserve'].contains(o.kind),
    )) {
      entry.status = 'Cloud pending: pending work is retained.';
      return;
    }
    if (artifacts.hasLegacyOrUncertain) {
      entry.status =
          'Cloud pending: untracked or changed recovery files are retained.';
      return;
    }
    final fromQuarantine =
        existing?.staged != null && info(existing!.staged!) != null;
    if (!fromQuarantine &&
        (!entry.expectedPresent ||
            entry.baselineHash == null ||
            entry.localHash != entry.baselineHash ||
            entry.etag == null)) {
      entry.status =
          'Cloud pending: local bytes are not yet clean and synchronized.';
      return;
    }
    final op =
        existing ??
        Operation(
          uniqueId(),
          'evict',
          entry.path,
          expectedEtag: entry.etag,
          hash: entry.baselineHash,
        );
    if (!fromQuarantine &&
        (op.hash != entry.baselineHash || op.expectedEtag != entry.etag)) {
      op.hash = entry.baselineHash;
      op.expectedEtag = entry.etag;
      op.data.clear();
      op.phase = 'prepared';
    }
    manifest.operations[op.id] = op;
    final initial = fromQuarantine
        ? info(op.staged!)!
        : artifacts.native.info(tree.fd, entry.path);
    op.data['binding'] = binding;
    op.data['identity'] = initial.identity;
    op.data['local'] = initial.toJson();
    op.staged ??= tree.durablePath(
      artifacts.reserve(entry.path, 'eviction-quarantine', create: false),
    );
    manifest.save();
    if (!proof(op)) {
      final file = artifacts.reserve(entry.path, 'eviction-proof');
      await cloud.download(entry.path, file, etag: op.expectedEtag!);
      rootCurrent();
      final actual = await hash(file);
      rootCurrent();
      artifacts.complete(file, hash: actual, etag: op.expectedEtag);
      if (actual != op.hash) {
        entry.status = 'Cloud pending: remote bytes differ from the recorded local content.';
        manifest.save();
        return;
      }
      op.data['provenHash'] = actual;
      op.data['provenEtag'] = op.expectedEtag;
      op.phase = 'proved';
      manifest.save();
    }
    if (fromQuarantine && op.phase == 'reclaiming' && proof(op)) {
      removeMissingArtifacts(op);
      manifest.save();
    }
    // No network below this point. Every cleanup candidate is an explicitly
    // recorded, unchanged clean artifact of this entry/version.
    final candidates = artifacts.records
        .where(
          (o) =>
              (o.data['entryPath'] ?? o.path) == entry.path &&
              o.phase == 'complete' &&
              o.hash == op.hash &&
              o.expectedEtag == op.expectedEtag &&
              o.data['role'] != 'working' &&
              o.data['role'] != 'preserved' &&
              o.staged != op.staged,
        )
        .toList();
    rootCurrent();
    final main = fromQuarantine
        ? info(op.staged!)!
        : artifacts.native.info(tree.fd, entry.path);
    if (main.identity != initial.identity || main.stamp != initial.stamp) {
      entry.status = 'Cloud pending: local file changed during remote proof.';
      manifest.save();
      return;
    }
    final aliases = <Operation>[];
    final separate = <Operation>[];
    for (final record in candidates) {
      if (record.data['directoryIdentity'] !=
          tree.native.identity(tree.stageFd)) {
        throw const FileSystemException(
          'Cloud pending: staging directory changed.',
        );
      }
      final actual = info(record.staged!);
      if (actual == null || actual.identity != record.data['identity']) {
        throw const FileSystemException(
          'Cloud pending: artifact identity changed.',
        );
      }
      (actual.identity == main.identity ? aliases : separate).add(record);
    }
    final guards = <int>[];
    final native = artifacts.native;
    try {
      rootCurrent();
      final fd = native.guard(
        fromQuarantine ? tree.stageFd : tree.fd,
        fromQuarantine ? p.basename(op.staged!) : entry.path,
        main,
        links: 1 + aliases.length,
      );
      guards.add(fd);
      if (native.hash(fd) != op.hash) {
        throw const FileSystemException('Cloud pending: local bytes changed.');
      }
      barrier?.call('before-quarantine', op, fd);
      rootCurrent();
      native.valid(fd);
      if (!fromQuarantine) {
        final plannedTarget = artifacts.record(File(op.staged!))!;
        plannedTarget.data['identity'] = initial.identity;
        plannedTarget.data['sourceRoot'] = entry.path;
        plannedTarget.hash = op.hash;
        plannedTarget.expectedEtag = op.expectedEtag;
        plannedTarget.phase = 'quarantining';
        op.phase = 'quarantining';
        manifest.save();
        rootCurrent();
        native.quarantine(
          fd,
          tree.fd,
          entry.path,
          tree.stageFd,
          p.basename(op.staged!),
        );
        tree.own(entry.path);
        barrier?.call('after-rename-before-db', op, fd);
        rootCurrent();
        final target = artifacts.record(File(op.staged!))!;
        final moved = native.infoFd(fd);
        target.data['identity'] = moved.identity;
        target.hash = op.hash;
        target.expectedEtag = op.expectedEtag;
        target.phase = 'complete';
        entry.expectedPresent = false;
        op.phase = 'quarantined';
        manifest.save();
      }
      barrier?.call('quarantined', op, fd);
      rootCurrent();
      native.valid(fd);
      if (native.hash(fd) != op.hash) {
        throw const FileSystemException(
          'Cloud pending: quarantined bytes changed.',
        );
      }
      for (final record in separate) {
        rootCurrent();
        native.valid(fd);
        final actual = info(record.staged!)!;
        final other = native.guard(
          tree.stageFd,
          p.basename(record.staged!),
          actual,
          links: 1,
        );
        guards.add(other);
        if (native.hash(other) != record.hash) {
          throw const FileSystemException(
            'Cloud pending: staged bytes changed.',
          );
        }
      }
      op.data['artifacts'] = [
        ...aliases,
        ...separate,
      ].map((o) => o.id).toList();
      op.phase = 'reclaiming';
      manifest.save();
      barrier?.call('before-final-unlink', op, fd);
      rootCurrent();
      native.valid(fd);
      for (var i = 0; i < separate.length; i++) {
        rootCurrent();
        native.valid(fd);
        native.unlink(
          guards[i + 1],
          tree.stageFd,
          p.basename(separate[i].staged!),
        );
      }
      for (final alias in aliases) {
        rootCurrent();
        native.valid(fd);
        native.unlink(fd, tree.stageFd, p.basename(alias.staged!));
      }
      rootCurrent();
      native.valid(fd);
      native.unlink(fd, tree.stageFd, p.basename(op.staged!));
      barrier?.call('after-final-unlink', op, fd);
    } finally {
      for (final fd in guards.reversed) {
        native.close(fd);
      }
    }
    rootCurrent();
    complete(op, entry, false);
    if (entry.preservedCopies.isNotEmpty) {
      entry.status = 'cloud-only; recovery copies retained';
    }
  }
}
