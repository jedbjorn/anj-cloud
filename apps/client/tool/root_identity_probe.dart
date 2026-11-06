import 'dart:io';

import 'package:anj_cloud/core/state/manifest.dart';
import 'package:anj_cloud/core/local/root_identity.dart';
import 'package:anj_cloud/core/local/root_tree.dart';
import 'package:anj_cloud/platform/native/native_root_fs.dart';

/// Offline proof harness for the legacy root-identity migration.
///
/// Usage: `dart run tool/root_identity_probe.dart PROFILE_COPY SCRATCH`
///
/// PROFILE_COPY must be a disposable COPY of a profile directory (its
/// manifest.sqlite is updated as the worker would update it). The root named
/// by its `root` setting is opened read-only: the migration only stats and
/// hashes it. Staging is redirected into SCRATCH, so the real staging
/// directory is not touched either. No network, no sync engine.
void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: root_identity_probe <profile-copy> <scratch>');
    exit(64);
  }
  final manifest = Manifest(Directory(arguments[0]));
  final native = NativeRootFs();
  RootTree? tree;
  try {
    final root = manifest.setting('root')!;
    final stored = manifest.setting('rootIdentity');
    tree = RootTree(
      Directory(root),
      Directory('${arguments[1]}/staging'),
      native,
    );
    final info = native.rootInfo(tree.fd);
    stdout.writeln('root:            $root');
    stdout.writeln('stored identity: $stored');
    stdout.writeln('current legacy:  ${info.legacy}');
    stdout.writeln('current stable:  ${info.identity} (stable=${info.stable})');
    final legacy = RegExp(r'^(\d+):\d+$').firstMatch(stored ?? '');
    if (legacy != null && info.stable) {
      final evidence = evaluateLegacyRoot(
        manifest,
        tree,
        legacy.group(1)!,
        info.identity.split(':').first,
      );
      stdout.writeln(
        'evidence:        accepted=${evidence.accepted} '
        'inodeProven=${evidence.inodeProven} '
        'contentProven=${evidence.contentProven} '
        'forward=${evidence.forward} R=${evidence.reference}',
      );
      stdout.writeln('                 ${evidence.detail}');
    }
    final result = acceptRoot(manifest, tree);
    stdout.writeln(
      'outcome:         ${result.outcome.name} (${result.detail})',
    );
    stdout.writeln('stored after:    ${manifest.setting('rootIdentity')}');
    final stamps = manifest.entries.values
        .map((e) => e.localStamp)
        .whereType<String>()
        .toList();
    stdout.writeln(
      'entry stamps:    ${stamps.where((s) => s.startsWith('f')).length} '
      'stable / ${stamps.length} recorded',
    );
    exitCode = result.outcome == RootOutcome.refused ? 1 : 0;
  } finally {
    tree?.close();
    manifest.close();
  }
}
