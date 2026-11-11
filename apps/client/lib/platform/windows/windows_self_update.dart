import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ports/self_update.dart';
import '../../core/update/release.dart';

/// The Windows [SelfUpdatePort] (the in-app update), with the Linux
/// contract (lib/platform/linux/manager_self_update.dart): the running
/// release's `bundle-receipt.json` (stamped by tool/windows/package.ps1
/// with `-VersionCode` and `-Version`) names this build, and the manager
/// beside the executable (`anj-cloud-manager.exe`, [command]) installs an
/// update with `apply-update` (tool/windows_manager).
///
/// The manager's plain `update` refuses while the app runs (the app holds
/// the profile lock). `apply-update` is started detached instead: it
/// verifies the download again by the release key built into the installed
/// release, waits for this process to release the profile lock by exiting,
/// installs a new release directory beside this one (a running release is
/// never changed in place), writes its outcome and starts the app again.
///
/// Only an installed release updates itself: an unpacked archive or a
/// development build (no receipt version, or not the release the manager's
/// activation record names) has no in-app update.
class WindowsManagerSelfUpdate implements SelfUpdatePort {
  WindowsManagerSelfUpdate(
    this.command, {
    String? executable,
    this.makePrivate,
    this.timeout = const Duration(minutes: 2),
  }) : executable = executable ?? Platform.resolvedExecutable;
  final String command;

  /// `<installation>\releases\<release>\anj_cloud.exe`.
  final String executable;

  /// Makes a directory private to this user (anj_rootfs.dll's privateDir).
  final void Function(String path)? makePrivate;
  final Duration timeout;

  static const _prefix = 'anj-cloud-manager: ';

  @override
  Future<InstalledBuild?> installed() async {
    final release = File(executable).parent;
    try {
      final data = jsonDecode(
        await File(p.join(release.path, 'bundle-receipt.json')).readAsString(),
      );
      if (data is! Map ||
          data['platform'] != 'Windows x86_64' ||
          data['version_code'] is! int ||
          data['version'] is! String) {
        return null;
      }
      // `<installation>\active.json`, two levels above the release.
      final active = jsonDecode(
        await File(p.join(release.parent.parent.path, 'active.json'))
            .readAsString(),
      );
      if (active is! Map || active['release'] != p.basename(release.path)) {
        return null;
      }
      return InstalledBuild(
        target: windowsReleaseTarget,
        version: data['version'] as String,
        versionCode: data['version_code'] as int,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The staging folder is inside the profile, which is already private;
  /// this keeps it so even if it was created by something else.
  @override
  Future<void> prepare(Directory directory) async {
    try {
      makePrivate?.call(directory.path);
    } on Object {
      throw const SelfUpdateFailure(
        'The update folder could not be made private.',
      );
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
      // The manager's own refusal; anything else it printed is not for
      // the status line.
      final reason = const LineSplitter()
          .convert('${result.stderr}')
          .map((line) => line.trim())
          .where((line) => line.startsWith(_prefix))
          .map((line) => line.substring(_prefix.length))
          .lastOrNull;
      throw SelfUpdateFailure(
        reason == null || reason.isEmpty
            ? 'The installed manager refused the update.'
            : reason,
      );
    }
  }

  @override
  Future<void> handOver(File archive, File manifest, File result) async {
    try {
      // Detached: no console and no stdio tied to this process, so it
      // outlives the app. It waits for the profile lock this process holds
      // until it exits; the manager never inherits it.
      await Process.start(command, [
        ..._arguments(archive, manifest),
        '--result',
        result.path,
        // How the manager tells this process quitting slowly from the app
        // having been started again.
        '--app-pid',
        '$pid',
      ], mode: ProcessStartMode.detached);
    } on Exception catch (error) {
      throw SelfUpdateFailure('The installed manager could not start: $error');
    }
  }
}
