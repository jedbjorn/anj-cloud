import 'dart:convert';
import 'dart:io';

import '../../core/ports/self_update.dart';
import '../../core/update/release.dart';

/// The macOS [SelfUpdatePort] (spec #40 R2), with the Linux contract
/// (lib/platform/linux/manager_self_update.dart): the running bundle's
/// release receipt (`Contents/Resources/bundle-receipt.json`, stamped by
/// tool/macos/package_release.sh) names this build, and the manager
/// embedded in the bundle (`Contents/Resources/anj-cloud-macos-install.sh`,
/// [command]) installs an update with `apply-update`. That manager has the
/// installed app's own executable verify the download again
/// (`--verify-update`, the Ed25519 check by the key built into this bundle)
/// before its journalled swap; a build without a receipt (a development
/// build) cannot update itself.
class MacosManagerSelfUpdate implements SelfUpdatePort {
  MacosManagerSelfUpdate(
    this.command, {
    String? executable,
    this.timeout = const Duration(minutes: 2),
  }) : executable = executable ?? Platform.resolvedExecutable;
  final String command;

  /// `<bundle>/Contents/MacOS/AnJ Cloud`.
  final String executable;
  final Duration timeout;

  @override
  Future<InstalledBuild?> installed() async {
    final contents = File(executable).parent.parent;
    final receipt = File('${contents.path}/Resources/bundle-receipt.json');
    try {
      final data = jsonDecode(await receipt.readAsString());
      if (data is! Map ||
          data['target'] != macosReleaseTarget ||
          data['version_code'] is! int ||
          data['version'] is! String) {
        return null;
      }
      return InstalledBuild(
        target: macosReleaseTarget,
        version: data['version'] as String,
        versionCode: data['version_code'] as int,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Dart creates directories without a mode; the manager refuses a
  /// staging folder others could read or write.
  @override
  Future<void> prepare(Directory directory) async {
    final result = await Process.run('/bin/chmod', ['0700', directory.path]);
    if (result.exitCode != 0) {
      throw SelfUpdateFailure('The update folder could not be made private.');
    }
  }

  List<String> _arguments(File archive, File manifest) => [
    'apply-update',
    archive.path,
    '--manifest',
    manifest.path,
  ];

  @override
  Future<void> check(File archive, File manifest) async {
    final ProcessResult result;
    try {
      result = await Process.run(command, [
        ..._arguments(archive, manifest),
        '--check',
      ]).timeout(timeout);
    } on Exception catch (error) {
      throw SelfUpdateFailure('The installed manager could not run: $error');
    }
    if (result.exitCode != 0) {
      final reason = '${result.stderr}'
          .trim()
          .split('\n')
          .last
          .replaceFirst('anj-cloud: ', '');
      throw SelfUpdateFailure(
        reason.isEmpty ? 'The installed manager refused the update.' : reason,
      );
    }
  }

  @override
  Future<void> handOver(File archive, File manifest, File result) async {
    try {
      // Detached (its own session) so it outlives this process; it copies
      // itself out of the bundle it is about to replace, waits for this
      // process to exit, installs and starts the new release.
      await Process.start(command, [
        ..._arguments(archive, manifest),
        '--result',
        result.path,
        '--app-pid',
        '$pid',
      ], mode: ProcessStartMode.detached);
    } on Exception catch (error) {
      throw SelfUpdateFailure('The installed manager could not start: $error');
    }
  }
}
