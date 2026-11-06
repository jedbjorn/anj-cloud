import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import '../gateway/cloud_api.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';
import 'sync_path_policy.dart';

/// Adopt a policy without pretending that old excluded mutations never ran.
/// The original row, IDs, binding metadata and private paths survive in the
/// same SQLite transaction that removes them from active reconciliation.
class ExcludedTracking {
  ExcludedTracking(this.manifest, this.tree, this.cloud, this.artifacts);
  final Manifest manifest;
  final RootTree tree;
  final CloudApi cloud;
  final Artifacts artifacts;
  void Function(String)? barrier;

  void adopt() {
    var changed = false;
    for (final entry in manifest.entries.values.toList()) {
      if (!isSyncExcluded(entry.path)) continue;
      changed = true;
      final archive = Operation(uniqueId(), 'excluded-entry', entry.path)
        ..data = {'policyVersion': 1, 'entry': entry.toJson()};
      manifest.operations[archive.id] = archive;
      manifest.entries.remove(entry.path);
    }
    for (final op in manifest.operations.values.toList()) {
      if (!isSyncExcluded(op.path) ||
          op.kind.startsWith('excluded-') ||
          (op.kind == 'artifact' && op.data['syncExcluded'] == true)) {
        continue;
      }
      changed = true;
      if (op.kind == 'artifact') {
        // Ownership is independent of sync participation. Retaining this index
        // keeps excluded private bytes known without ever dispatching them.
        op.data['excludedHistory'] = {
          ...op.toJson(),
          'data': Map<String, dynamic>.from(op.data),
        };
        op.data['syncExcluded'] = true;
        continue;
      }
      final definitelyUnsent = op.data['dispatchState'] == 'not-started';
      manifest.operations[op.id] =
          Operation(
              op.id,
              'excluded-operation',
              op.path,
              expectedEtag: op.expectedEtag,
              staged: op.staged,
              hash: op.hash,
              phase: definitelyUnsent
                  ? 'cancelled-before-dispatch'
                  : 'retained-history',
            )
            ..data = {
              'policyVersion': 1,
              'original': op.toJson(),
              'outcome': definitelyUnsent
                  ? 'Stopped before dispatch; bytes retained.'
                  : 'Previous dispatch/effect may be uncertain; never replayed by exclusion adoption.',
            };
    }
    if (!changed) return;
    barrier?.call('before-commit');
    manifest.save();
    barrier?.call('after-commit');
  }

  /// Inspect historical uncertainty only. Never retry an excluded mutation.
  /// A matching remote body is an observation, not attribution of its creator.
  Future<void> observe(Map<String, RemoteItem> unfilteredRemote) async {
    for (final archived
        in manifest.operations.values
            .where(
              (o) =>
                  o.kind == 'excluded-operation' &&
                  o.phase != 'cancelled-before-dispatch',
            )
            .toList()) {
      final original = Operation.fromJson(
        Map<String, dynamic>.from(archived.data['original'] as Map),
      );
      if (!['upload', 'delete'].contains(original.kind)) continue;
      final remote = unfilteredRemote[archived.path];
      if (archived.data['observed'] == true) continue;
      archived.data['observed'] = true;
      archived.data['observedEtag'] = remote?.etag;
      archived.data['observation'] = remote == null
          ? 'Remote absence observed; previous mutation attribution remains unknown.'
          : 'Remote version observed; previous mutation attribution remains unknown.';
      manifest.save();
      if (original.kind != 'upload' ||
          original.hash == null ||
          remote == null ||
          remote.kind != ItemKind.file) {
        continue;
      }
      // Only legacy uncertain upload recovery permits this bounded content read;
      // ordinary excluded remote entries are never downloaded/materialized.
      final proof = artifacts.reserve(archived.path, 'excluded-recovery-proof');
      archived.data['proofArtifact'] = artifacts.record(proof)!.id;
      manifest.save();
      try {
        await cloud.download(archived.path, proof, etag: remote.etag);
        tree.native.checkRoot(tree.fd, tree.root.path);
        tree.native.checkRoot(tree.stageFd, tree.staging.path);
        final hash = tree.native.copyAndHash(
          tree.stageFd,
          p.basename(proof.path),
          null,
          purpose: 'excluded-recovery',
        );
        artifacts.complete(proof, hash: hash, etag: remote.etag);
        archived.data['observedHash'] = hash;
        archived.data['matchesRequestedUpload'] = hash == original.hash;
        archived.data['observation'] = hash == original.hash
            ? 'Conditional remote content matches the old upload snapshot; no mutation replayed.'
            : 'Remote content differs from the old upload snapshot; all private versions retained.';
      } on FileSystemException {
        archived.data['observation'] = 'Remote verification incomplete; private bytes/history retained, no replay.';
      } on CloudFailure {
        archived.data['observation'] = 'Remote verification incomplete; private bytes/history retained, no replay.';
      } catch (_) {
        archived.data['observation'] = 'Remote verification incomplete; private bytes/history retained, no replay.';
      }
      manifest.save();
    }
    // Proof artifacts are recovery history too, not new active ignored work.
    adopt();
  }
}
