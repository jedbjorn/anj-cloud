import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import '../gateway/cloud_api.dart';
import '../ports/release_guard.dart';
import '../state/manifest.dart';
import '../state/model.dart';
import '../local/root_tree.dart';

/// User-confirmed session completion. Uploads remain the reconciler's job.
/// Reclamation uses a separate journal because a Cloud entry need not have a
/// materialized root file. No network awaits occur while leases are held.
class EditCompletion {
  EditCompletion(this.manifest, this.tree, this.cloud, this.artifacts);
  final Manifest manifest;
  final RootTree tree;
  final CloudApi cloud;
  final Artifacts artifacts;
  void Function(String, Operation, int)? barrier;
  String get binding =>
      '${manifest.profile.resolveSymbolicLinksSync()}|${manifest.setting('accountOrigin') ?? ''}|${manifest.setting('accountUid') ?? ''}';
  Iterable<Operation> get requests =>
      manifest.operations.values.where((o) => o.kind == 'finish-editing');
  List<String> ids(Operation request, String key) =>
      (request.data[key] as List? ?? []).cast<String>();
  List<Map<String, dynamic>> plans(Operation request) =>
      (request.data['plan'] as List? ?? []).cast<Map<String, dynamic>>();
  void current() {
    tree.native.checkRoot(tree.fd, tree.root.path);
    tree.native.checkRoot(tree.stageFd, tree.staging.path);
  }

  NativeFileInfo? info(String name) {
    try {
      return artifacts.native.info(tree.stageFd, name);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  /// Called only after the authenticated conditional upload returned success.
  void acceptUpload(
    Operation session,
    Operation buffer,
    String etag,
    String hash,
  ) {
    if (buffer.hash != hash || buffer.expectedEtag != etag) {
      throw StateError('Upload receipt mismatch');
    }
    buffer.data['accepted'] = true;
    buffer.data['snapshotHash'] = hash;
    buffer.data['snapshotIdentity'] = buffer.data['identity'];
    final previous = manifest.operations[session.data['uploadTip']];
    if (previous != null &&
        previous.kind == 'artifact' &&
        previous.data['workingId'] == session.id &&
        previous.data['lineageVersion'] == 1 &&
        previous.data['sessionBinding'] == binding &&
        previous.data['accepted'] == true &&
        previous.expectedEtag == buffer.data['baseEtag'] &&
        previous.hash == session.hash) {
      previous.data['supersededBy'] = buffer.id;
      buffer.data['supersedes'] = previous.id;
    }
    session.data['uploadTip'] = buffer.id;
  }

  List<Map<String, dynamic>>? supersession(
    Operation first,
    Operation request,
    RemoteItem remote,
    String finalHash,
  ) {
    final sessionId = first.data['workingId'];
    if (!ids(request, 'sessions').contains(sessionId)) return null;
    final session = manifest.operations[sessionId];
    if (session?.kind != 'working') return null;
    final chain = <Map<String, dynamic>>[];
    final visited = <String>{};
    Operation? record = first;
    while (record != null && visited.add(record.id)) {
      if (record.kind != 'artifact' ||
          record.path != request.path ||
          record.phase != 'complete' ||
          record.data['role'] != 'working-upload' ||
          record.data['lineageVersion'] != 1 ||
          record.data['workingId'] != sessionId ||
          record.data['sessionBinding'] != binding ||
          record.data['accepted'] != true ||
          record.hash == null ||
          record.expectedEtag == null ||
          record.hash != record.data['snapshotHash'] ||
          record.data['identity'] != record.data['snapshotIdentity']) {
        return null;
      }
      chain.add({
        'id': record.id,
        'session': sessionId,
        'binding': binding,
        'path': record.path,
        'hash': record.hash,
        'identity': record.data['identity'],
        'etag': record.expectedEtag,
        'baseEtag': record.data['baseEtag'],
        'next': record.data['supersededBy'],
        'previous': record.data['supersedes'],
      });
      final next = manifest.operations[record.data['supersededBy']];
      if (next == null) {
        if (record.data['supersededBy'] == null &&
            record.id == session!.data['uploadTip'] &&
            record.expectedEtag == remote.etag &&
            record.hash == finalHash &&
            chain.length > 1) {
          return chain;
        }
        return null;
      }
      if (next.data['supersedes'] != record.id ||
          next.data['baseEtag'] != record.expectedEtag) {
        return null;
      }
      record = next;
    }
    return null;
  }

  bool planProof(Operation request, Map<String, dynamic> plan) {
    if (plan['proofKind'] == 'current') return plan['hash'] == request.hash;
    if (plan['proofKind'] != 'superseded-upload') return false;
    final chain = (plan['chain'] as List? ?? []).cast<Map>();
    if (chain.length < 2 ||
        !ids(request, 'sessions').contains(chain.first['session']) ||
        chain.first['id'] != plan['artifact'] ||
        chain.first['identity'] != plan['identity'] ||
        chain.first['hash'] != plan['hash'] ||
        chain.last['hash'] != request.hash ||
        chain.last['etag'] != request.expectedEtag ||
        chain.last['next'] != null) {
      return false;
    }
    final seen = <Object?>{};
    for (var i = 0; i < chain.length; i++) {
      final link = chain[i];
      if (!seen.add(link['id']) ||
          link['session'] != chain.first['session'] ||
          link['binding'] != binding ||
          link['path'] != request.path ||
          link['hash'] == null ||
          link['etag'] == null) {
        return false;
      }
      if (i > 0 &&
          (chain[i - 1]['next'] != link['id'] ||
              link['previous'] != chain[i - 1]['id'] ||
              link['baseEtag'] != chain[i - 1]['etag'])) {
        return false;
      }
    }
    return true;
  }

  void request(String path, List<Map<String, dynamic>> previews) {
    if (manifest.setting('retention') == 'cloud') {
      throw const CloudFailure(
        'Storage upgrade pending: finish preserving existing storage choices before Finish editing.',
      );
    }
    final relevant = manifest.operations.values
        .where(
          (o) =>
              o.kind == 'working' &&
              o.path == path &&
              previews.any((v) => v['id'] == o.id),
        )
        .map((o) => o.id)
        .toSet();
    if (relevant.isEmpty) return;
    final request =
        requests.where((o) => o.path == path).firstOrNull ??
        (Operation(uniqueId(), 'finish-editing', path)
          ..data['binding'] = binding);
    if (request.data['binding'] != binding) {
      throw const FileSystemException(
        'Finish pending: profile/account binding changed.',
      );
    }
    final authorization = Map<String, dynamic>.from(
      request.data['previews'] as Map? ?? {},
    );
    final transitions = <Operation>[];
    for (final claim in previews.where((v) => relevant.contains(v['id']))) {
      final work = manifest.operations[claim['id']]!;
      final record = artifacts.record(artifacts.resolve(work.staged!));
      final preview = claim['preview'] as Map?;
      final actual = artifacts.native.preview(
        tree.stageFd,
        p.basename(work.staged!),
      );
      if (record == null ||
          preview == null ||
          preview['stamp'] != actual.stamp ||
          preview['directoryIdentity'] != tree.native.identity(tree.stageFd) ||
          record.data['directoryIdentity'] != preview['directoryIdentity']) {
        throw const FileSystemException(
          'Finish pending: file changed since preview; review the current copies and confirm again.',
        );
      }
      authorization[work.id] = Map<String, dynamic>.from(preview);
      if (actual.identity != record.data['identity']) {
        final transition =
            Operation(
                uniqueId(),
                'edit-ownership',
                path,
                staged: work.staged,
                phase: 'authorized',
              )
              ..data = {
                'request': request.id,
                'session': work.id,
                'artifact': record.id,
                'previousIdentity': record.data['identity'],
                'confirmedIdentity': actual.identity,
                'confirmedStamp': actual.stamp,
                'directoryIdentity': preview['directoryIdentity'],
                'authority': 'Explicit user confirmation of this displayed completed edit result',
              };
        transitions.add(transition);
      }
    }
    for (final previous in manifest.operations.values.where(
      (o) =>
          o.kind == 'edit-ownership' &&
          o.data['request'] == request.id &&
          relevant.contains(o.data['session']) &&
          o.phase == 'authorized',
    )) {
      previous.phase = 'superseded';
    }
    for (final transition in transitions) {
      manifest.operations[transition.id] = transition;
    }
    final previousProof = manifest.operations[request.data['proofArtifact']];
    if (previousProof != null && previousProof.phase != 'complete') {
      request.data.remove('proofArtifact');
    }
    request.data['previews'] = authorization;
    request.data['sessions'] = {
      ...ids(request, 'sessions'),
      ...relevant,
    }.toList();
    final confirmed = ids(request, 'sessions');
    final excludedPaths = manifest.operations.values
        .where(
          (o) =>
              o.kind == 'working' &&
              o.path == path &&
              !confirmed.contains(o.id),
        )
        .map((o) => o.staged)
        .toSet();
    request.data['artifacts'] = {
      ...ids(request, 'artifacts'),
      ...artifacts.records
          .where(
            (o) =>
                (o.data['entryPath'] ?? o.path) == path &&
                !excludedPaths.contains(o.staged),
          )
          .map((o) => o.id),
    }.toList();
    manifest.operations[request.id] = request;
    manifest.save();
  }

  void remap(Entry entry, String from, String to) {
    for (final op in manifest.operations.values) {
      if (op.path == entry.path && op.staged == from) op.staged = to;
    }
    entry.preservedCopies = entry.preservedCopies
        .map((v) => v == from ? to : v)
        .toList();
    if (entry.workingCopy == from) entry.workingCopy = to;
  }

  void forget(Operation request, Entry entry, Map<String, dynamic> plan) {
    final paths = [
      p.join(tree.staging.path, plan['from'] as String),
      p.join(tree.staging.path, plan['to'] as String),
    ];
    manifest.operations.remove(plan['artifact']);
    manifest.operations.removeWhere(
      (id, op) =>
          op.path == entry.path &&
          paths.contains(op.staged) &&
          (op.kind == 'retained' ||
              (op.kind == 'working' && ids(request, 'sessions').contains(id))),
    );
    entry.preservedCopies.removeWhere(paths.contains);
    if (paths.contains(entry.workingCopy)) entry.workingCopy = null;
  }

  /// Only durable, proven reclaim intent permits acknowledging absent bytes.
  void recover() {
    for (final request in requests.toList()) {
      final entry = manifest.entries[request.path];
      if (entry == null || request.data['binding'] != binding) continue;
      for (final plan in plans(request)) {
        final to = info(plan['to'] as String);
        final from = info(plan['from'] as String);
        if ((from != null && from.identity != plan['identity']) ||
            (to != null && to.identity != plan['identity'])) {
          request.data['recoveryIssue'] = 'A completion slot was replaced; both paths are retained for recovery.';
          final unexpected = p.join(
            tree.staging.path,
            from != null ? plan['from'] as String : plan['to'] as String,
          );
          if (!entry.preservedCopies.contains(unexpected)) {
            entry.preservedCopies.add(unexpected);
          }
          continue;
        }
        if (to != null && to.identity == plan['identity']) {
          final target = p.join(tree.staging.path, plan['to'] as String);
          remap(
            entry,
            p.join(tree.staging.path, plan['from'] as String),
            target,
          );
          final record = manifest.operations[plan['artifact']];
          if (record != null) record.data['name'] = plan['to'];
          for (final work in manifest.operations.values.where(
            (o) =>
                o.kind == 'working' &&
                ids(request, 'sessions').contains(o.id) &&
                o.staged == target,
          )) {
            final preview =
                (request.data['previews'] as Map?)?[work.id] as Map?;
            if (preview != null &&
                preview['identity'] == to.identity &&
                (plan['renamedStamp'] == to.stamp ||
                    (plan['renamedStamp'] == null &&
                        (preview['stamp'] as String)
                                .split(':')
                                .take(5)
                                .join(':') ==
                            to.stamp.split(':').take(5).join(':')))) {
              preview['stamp'] = to.stamp;
            }
          }
        } else if (to == null &&
            request.phase == 'reclaiming' &&
            request.hash != null &&
            request.expectedEtag != null &&
            request.data['provenHash'] == request.hash &&
            request.data['provenEtag'] == request.expectedEtag &&
            planProof(request, plan) &&
            from == null) {
          forget(request, entry, plan);
        }
      }
      manifest.save();
    }
  }

  Future<void> run(Entry entry, RemoteItem? remote, Retention retention) async {
    final request = requests.where((o) => o.path == entry.path).firstOrNull;
    if (request == null) return;
    try {
      current();
      if (request.data['binding'] != binding) {
        throw const FileSystemException('profile/account binding changed');
      }
      if (request.data['recoveryIssue'] != null) {
        throw FileSystemException(request.data['recoveryIssue'] as String);
      }
      if (entry.conflict != null) {
        throw const FileSystemException('resolve conflicting versions first');
      }
      final sessions = manifest.operations.values
          .where(
            (o) =>
                o.kind == 'working' && ids(request, 'sessions').contains(o.id),
          )
          .toList();
      final scopedArtifactsRemain = artifacts.records.any(
        (o) =>
            ids(request, 'artifacts').contains(o.id) ||
            ids(request, 'sessions').contains(o.data['workingId']),
      );
      if (sessions.isEmpty && !scopedArtifactsRemain) {
        manifest.operations.remove(request.id);
        manifest.save();
        return;
      }
      if (remote == null || remote.kind != ItemKind.file) {
        throw const FileSystemException('remote file is unavailable');
      }
      if (retention == Retention.local && !entry.expectedPresent) {
        throw const FileSystemException(
          'required Local root copy is not ready',
        );
      }
      // Reuse only this request's unchanged, owned proof of the same ETag.
      // Busy/replaced copies must not cause a fresh download artifact every tick.
      var proofRecord = manifest.operations[request.data['proofArtifact']];
      File? proof;
      if (proofRecord != null &&
          proofRecord.phase == 'complete' &&
          proofRecord.expectedEtag == remote.etag) {
        final actual = info(proofRecord.data['name'] as String);
        if (actual?.identity == proofRecord.data['identity']) {
          proof = artifacts.resolve(proofRecord.staged!);
        }
      }
      if (proof == null &&
          proofRecord != null &&
          proofRecord.phase != 'complete') {
        throw const FileSystemException(
          'cloud verification was interrupted; review copies and Finish editing again to retry',
        );
      }
      if (proof == null) {
        proof = artifacts.reserve(entry.path, 'finish-proof');
        proofRecord = artifacts.record(proof)!;
        request.data['proofArtifact'] = proofRecord.id;
        request.data['artifacts'] = {
          ...ids(request, 'artifacts'),
          proofRecord.id,
        }.toList();
        manifest.save();
        await cloud.download(entry.path, proof, etag: remote.etag);
        current();
        final hash = tree.native.copyAndHash(
          tree.stageFd,
          p.basename(proof.path),
          null,
          purpose: 'finish-editing',
        );
        artifacts.complete(proof, hash: hash, etag: remote.etag);
      }
      final hash = tree.native.copyAndHash(
        tree.stageFd,
        p.basename(proof.path),
        null,
        purpose: 'finish-editing',
      );
      if (hash != proofRecord!.hash) {
        throw const FileSystemException(
          'owned cloud-proof bytes changed; retained',
        );
      }
      for (final session in sessions) {
        final file = artifacts.resolve(session.staged!);
        final record = artifacts.record(file);
        final actual = info(p.basename(file.path));
        final preview = (request.data['previews'] as Map?)?[session.id] as Map?;
        if (record == null ||
            actual == null ||
            preview == null ||
            actual.stamp != preview['stamp'] ||
            actual.identity != preview['identity'] ||
            !actual.owned ||
            actual.links != 1 ||
            preview['directoryIdentity'] !=
                tree.native.identity(tree.stageFd) ||
            record.data['directoryIdentity'] !=
                tree.native.identity(tree.stageFd)) {
          throw const FileSystemException(
            'file changed since completion preview or ownership is uncertain; confirm the current completed edits again',
          );
        }
        final actualHash = tree.native.copyAndHash(
          tree.stageFd,
          p.basename(file.path),
          null,
          purpose: 'finish-editing',
        );
        if (actualHash != hash || session.hash != hash) {
          throw const FileSystemException(
            'a saved editor version differs from the verified cloud version; all copies retained',
          );
        }
      }
      final allowed = {
        ...ids(request, 'artifacts'),
        ...artifacts.records
            .where(
              (o) => ids(request, 'sessions').contains(o.data['workingId']),
            )
            .map((o) => o.id),
      };
      final sessionPaths = sessions.map((o) => o.staged).toSet();
      final candidates = <Operation>[];
      final hashes = <String, String>{};
      final chains = <String, List<Map<String, dynamic>>>{};
      for (final record in artifacts.records.where(
        (o) => allowed.contains(o.id),
      )) {
        final actual = info(record.data['name'] as String);
        final confirmed = sessions
            .where((o) => o.staged == record.staged)
            .firstOrNull;
        final expectedIdentity = confirmed == null
            ? record.data['identity']
            : ((request.data['previews'] as Map)[confirmed.id]
                  as Map)['identity'];
        if (actual == null ||
            actual.identity != expectedIdentity ||
            record.data['directoryIdentity'] !=
                tree.native.identity(tree.stageFd)) {
          throw const FileSystemException(
            'cache identity changed; retained for recovery',
          );
        }
        if (record.phase != 'complete') continue;
        final actualHash = tree.native.copyAndHash(
          tree.stageFd,
          record.data['name'] as String,
          null,
          purpose: 'finish-editing',
        );
        if (sessionPaths.contains(record.staged) || actualHash == hash) {
          candidates.add(record);
          hashes[record.id] = hash;
        } else {
          var chain = supersession(record, request, remote, hash);
          // A crash may already have removed a chain node/session. Its exact
          // verified chain was persisted before unlink and remains authoritative
          // only for the same final remote version and this planned inode.
          final durable = plans(request)
              .where((v) => v['artifact'] == record.id)
              .firstOrNull;
          if (chain == null &&
              durable != null &&
              request.hash == hash &&
              request.expectedEtag == remote.etag &&
              planProof(request, durable) &&
              durable['proofKind'] == 'superseded-upload' &&
              durable['identity'] == actual.identity &&
              durable['hash'] == record.hash) {
            chain = (durable['chain'] as List).cast<Map<String, dynamic>>();
          }
          if (chain != null && actualHash == record.hash) {
            candidates.add(record);
            hashes[record.id] = record.hash!;
            chains[record.id] = chain;
          }
        }
      }
      // Guard every inode and account for all owned names, including a retained
      // Local root alias. Unknown hardlinks make the native guard refuse.
      final groups = <String, List<Operation>>{};
      for (final record in candidates) {
        groups
            .putIfAbsent(
              info(record.data['name'] as String)!.identity,
              () => [],
            )
            .add(record);
      }
      final guards = <String, int>{};
      try {
        for (final group in groups.entries) {
          final actual = info(group.value.first.data['name'] as String)!;
          var links = group.value.length;
          try {
            if (artifacts.native.info(tree.fd, entry.path).identity ==
                group.key) {
              links++;
            }
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 2) rethrow;
          }
          final fd = artifacts.native.guard(
            tree.stageFd,
            group.value.first.data['name'] as String,
            actual,
            links: links,
          );
          guards[group.key] = fd;
          if (artifacts.native.infoFd(fd).identity != group.key) {
            throw const FileSystemException(
              'cache identity changed before guard',
            );
          }
          if (group.value.any(
                (o) => hashes[o.id] != hashes[group.value.first.id],
              ) ||
              artifacts.native.hash(fd, purpose: 'finish-editing') !=
                  hashes[group.value.first.id]) {
            throw const FileSystemException('cache changed during cloud proof');
          }
        }
        for (final session in sessions) {
          final preview = (request.data['previews'] as Map)[session.id] as Map;
          final held = artifacts.native.infoFd(guards[preview['identity']]!);
          if (held.identity != preview['identity'] ||
              held.stamp != preview['stamp']) {
            throw const FileSystemException(
              'completed edit changed after confirmation; confirm again',
            );
          }
        }
        // Distinct authorization was persisted before this transition. Leases
        // now bind the exact descriptor and bytes to the confirmed edit result.
        for (final transition in manifest.operations.values.where(
          (o) =>
              o.kind == 'edit-ownership' &&
              o.data['request'] == request.id &&
              o.phase == 'authorized',
        )) {
          final record = manifest.operations[transition.data['artifact']];
          if (record == null ||
              !guards.containsKey(transition.data['confirmedIdentity'])) {
            throw const FileSystemException(
              'confirmed replacement ownership could not be established',
            );
          }
          final held = artifacts.native.infoFd(
            guards[transition.data['confirmedIdentity']]!,
          );
          if (held.stamp != transition.data['confirmedStamp']) {
            throw const FileSystemException('confirmed replacement changed');
          }
          record.data['identity'] = held.identity;
          record.data['stamp'] = held.stamp;
          transition.phase = 'adopted';
        }
        manifest.save();
        if (artifacts.hasLegacyOrUncertain) {
          throw const FileSystemException(
            'untracked or replaced recovery files remain',
          );
        }
        request.hash = hash;
        request.expectedEtag = remote.etag;
        request.data['provenHash'] = hash;
        request.data['provenEtag'] = remote.etag;
        request.data['plan'] = candidates
            .map(
              (o) => <String, dynamic>{
                'artifact': o.id,
                'from': o.data['name'],
                'to': 'finished-${uniqueId()}',
                'identity': o.data['identity'],
                'hash': hashes[o.id],
                'proofKind': chains.containsKey(o.id)
                    ? 'superseded-upload'
                    : 'current',
                if (chains.containsKey(o.id)) 'chain': chains[o.id],
              },
            )
            .toList();
        request.phase = 'quarantining';
        manifest.save();
        for (final plan in plans(request)) {
          final fd = guards[plan['identity']]!;
          current();
          barrier?.call('before-quarantine', request, fd);
          artifacts.native.valid(fd);
          artifacts.native.quarantine(
            fd,
            tree.stageFd,
            plan['from'] as String,
            tree.stageFd,
            plan['to'] as String,
          );
          barrier?.call('after-rename-before-receipt', request, fd);
          plan['renamedStamp'] = artifacts.native.infoFd(fd).stamp;
          // Native rename fsyncs its directory before this durable receipt.
          manifest.save();
          barrier?.call('after-rename-before-db', request, fd);
          remap(
            entry,
            p.join(tree.staging.path, plan['from'] as String),
            p.join(tree.staging.path, plan['to'] as String),
          );
          manifest.operations[plan['artifact']]!.data['name'] = plan['to'];
          for (final session in sessions.where(
            (o) => o.staged == p.join(tree.staging.path, plan['to'] as String),
          )) {
            ((request.data['previews'] as Map)[session.id] as Map)['stamp'] =
                plan['renamedStamp'];
          }
          manifest.save();
        }
        for (final group in groups.entries) {
          final fd = guards[group.key]!;
          artifacts.native.valid(fd);
          if (artifacts.native.hash(fd, purpose: 'finish-editing') !=
              hashes[group.value.first.id]) {
            throw const FileSystemException('quarantined bytes changed');
          }
        }
        request.phase = 'reclaiming';
        manifest.save();
        for (final plan in plans(request)) {
          final fd = guards[plan['identity']]!;
          current();
          barrier?.call('before-final-unlink', request, fd);
          artifacts.native.valid(fd);
          artifacts.native.unlink(fd, tree.stageFd, plan['to'] as String);
          barrier?.call('after-unlink-before-db', request, fd);
        }
      } finally {
        for (final fd in guards.values.toList().reversed) {
          artifacts.native.close(fd);
        }
      }
      recover();
      if (request.data['recoveryIssue'] != null ||
          manifest.operations.values.any(
            (o) =>
                o.kind == 'working' && ids(request, 'sessions').contains(o.id),
          ) ||
          plans(request)
              .any((v) => manifest.operations.containsKey(v['artifact']))) {
        throw const FileSystemException(
          'completion interrupted or a slot was replaced; retained paths need recovery',
        );
      }
      manifest.operations.remove(request.id);
      entry.status = 'Editing finished; storage policy unchanged.';
      manifest.save();
    } catch (error) {
      recover();
      entry.status = 'Finish pending: $error';
      manifest.save();
    }
  }
}
