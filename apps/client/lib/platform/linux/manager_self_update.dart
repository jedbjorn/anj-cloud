import 'dart:convert';
import 'dart:io';

import '../../core/ports/self_update.dart';
import '../../core/update/release.dart';

/// The Linux [SelfUpdatePort] (spec #37 U-linux): the running bundle's
/// `bundle-receipt.json` (written by tool/package_linux.py and verified by
/// the manager at install) names this build, and the installed manager's
/// `apply-update` command (tool/linux_install.py) installs an update. Only
/// manager-launched builds know the stable [command].
class ManagerSelfUpdate implements SelfUpdatePort {
  ManagerSelfUpdate(
    this.command, {
    String? executable,
    this.timeout = const Duration(minutes: 2),
  }) : executable = executable ?? Platform.resolvedExecutable;
  final String command;
  final String executable;
  final Duration timeout;

  @override
  Future<InstalledBuild?> installed() async {
    final receipt = File('${File(executable).parent.path}/bundle-receipt.json');
    try {
      final data = jsonDecode(await receipt.readAsString());
      if (data is! Map ||
          data['platform'] != 'Linux x86_64' ||
          data['version_code'] is! int ||
          data['version'] is! String) {
        return null;
      }
      return InstalledBuild(
        target: linuxReleaseTarget,
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
    final result = await Process.run('/usr/bin/chmod', [
      '0700',
      directory.path,
    ]);
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
      final reason = '${result.stderr}'.trim().replaceFirst('anj-cloud: ', '');
      throw SelfUpdateFailure(
        reason.isEmpty ? 'The installed manager refused the update.' : reason,
      );
    }
  }

  @override
  Future<void> handOver(File archive, File manifest, File result) async {
    try {
      // Detached: its own session, no stdio tied to this process, so it
      // outlives the app. The profile lock is close-on-exec in the app
      // (native runner), so the manager never inherits it.
      await Process.start(command, [
        ..._arguments(archive, manifest),
        '--result',
        result.path,
        // Waited for even if the manager cannot read the installation.
        '--app-pid',
        '$pid',
      ], mode: ProcessStartMode.detached);
    } on Exception catch (error) {
      throw SelfUpdateFailure('The installed manager could not start: $error');
    }
  }
}
