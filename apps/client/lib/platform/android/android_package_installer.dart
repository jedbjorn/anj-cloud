import 'package:flutter/services.dart';

import '../../core/ports/package_installer.dart';

/// Android [PackageInstallerPort] (spec #28 A7) over `UpdateChannel.kt`:
/// `PackageManager` reads the installed app and the downloaded archive
/// (`GET_SIGNING_CERTIFICATES`), and a `PackageInstaller` session installs
/// with the user's confirmation always required.
class AndroidPackageInstaller implements PackageInstallerPort {
  const AndroidPackageInstaller();
  static const channel = MethodChannel('cloud.anj.anj_cloud/updater');

  @override
  Future<PackageFacts> installed() async => PackageFacts.fromMap(
    (await channel.invokeMapMethod<Object?, Object?>('installed'))!,
  );

  @override
  Future<PackageFacts?> inspect(String path) async {
    final facts = await channel.invokeMapMethod<Object?, Object?>('inspect', {
      'path': path,
    });
    return facts == null ? null : PackageFacts.fromMap(facts);
  }

  @override
  Future<bool> canRequestInstalls() async =>
      await channel.invokeMethod<bool>('canRequestInstalls') ?? false;

  @override
  Future<void> openInstallPermission() =>
      channel.invokeMethod<void>('openInstallPermission');

  @override
  Future<int?> freeBytes(String path) async =>
      (await channel.invokeMethod<num>('freeBytes', {'path': path}))?.toInt();

  @override
  Future<void> discardSessions() =>
      channel.invokeMethod<int>('discardSessions');

  @override
  Future<void> cancelInstall() => channel.invokeMethod<int>('cancelInstall');

  @override
  Future<InstallResult> install(
    String path, {
    required String sha256,
    required int size,
  }) async {
    final Map<Object?, Object?>? result;
    try {
      result = await channel.invokeMapMethod<Object?, Object?>('install', {
        'path': path,
        'sha256': sha256,
        'size': size,
      });
    } on PlatformException catch (error) {
      return InstallResult(
        InstallOutcome.failed,
        error.message ?? 'Android did not install the update.',
      );
    }
    final outcome = InstallOutcome.values.asNameMap()[result?['outcome']];
    return InstallResult(
      outcome ?? InstallOutcome.failed,
      result?['message'] as String?,
    );
  }
}
