import 'package:flutter/material.dart';

import '../core/state/model.dart';
import '../core/update/app_updater.dart';

/// The in-app updater's surface (spec #28 A7) in the status area: what is
/// on offer, progress, and every refusal with its reason. Nothing appears
/// while there is nothing to say.
class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key, required this.updater});
  final AppUpdater updater;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: updater,
    builder: (context, _) {
      final release = updater.manifest;
      final installed = updater.installedApp?.versionName;
      final offer = release == null
          ? 'An update'
          : 'Version ${release.version} (${sizeLabel(release.size)})';
      Widget action(String key, String label, VoidCallback onPressed) =>
          TextButton(
            key: ValueKey('update-$key'),
            onPressed: onPressed,
            child: Text(label),
          );
      Widget primary(String key, String label, VoidCallback onPressed) =>
          FilledButton(
            key: ValueKey('update-$key'),
            onPressed: onPressed,
            child: Text(label),
          );
      final later = action('later', 'Later', updater.dismiss);
      final (
        String? title,
        String? body,
        List<Widget> actions,
      ) = switch (updater.phase) {
        UpdatePhase.idle => (null, updater.message, const <Widget>[]),
        UpdatePhase.checking => (
          'Checking for updates…',
          null,
          const <Widget>[],
        ),
        UpdatePhase.upToDate => (
          'AnJ Cloud is up to date',
          installed == null ? null : 'Installed version $installed.',
          [action('dismiss', 'Dismiss', updater.dismiss)],
        ),
        UpdatePhase.available => (
          'Update available',
          '$offer is ready on your household server.',
          [
            primary(
              'download',
              'Download and install',
              updater.downloadAndInstall,
            ),
            later,
          ],
        ),
        UpdatePhase.waiting => (
          'Update waiting',
          updater.message,
          [action('retry', 'Try again', updater.downloadAndInstall), later],
        ),
        UpdatePhase.waitingForSync => (
          'Update waiting',
          updater.message,
          [later],
        ),
        UpdatePhase.downloading => (
          'Downloading update',
          release == null
              ? null
              : '${sizeLabel(updater.received)} of ${sizeLabel(release.size)}',
          [action('cancel-download', 'Cancel', updater.cancelDownload)],
        ),
        UpdatePhase.verifying => (
          'Checking the download',
          'Comparing its checksum, signing key and version with this app.',
          const <Widget>[],
        ),
        UpdatePhase.permission => (
          'Allow AnJ Cloud to install its updates',
          'Android asks once. Tap Open settings, turn on '
              '"Allow from this source", then come back: the update '
              'continues and Android asks you to confirm it.',
          [
            primary(
              'settings',
              'Open settings',
              updater.openPermissionSettings,
            ),
            action('cancel', 'Cancel', updater.dismiss),
          ],
        ),
        UpdatePhase.installing => (
          'Confirm the update',
          'Android is asking you to confirm installing $offer. If its '
              'screen is gone, tap Cancel and install again.',
          [action('cancel-install', 'Cancel', updater.cancelInstall)],
        ),
        UpdatePhase.declined => (
          'Update not installed',
          installed == null
              ? 'You declined it. Nothing changed.'
              : 'You declined it. AnJ Cloud stays at version $installed.',
          [primary('install', 'Install', updater.installAgain), later],
        ),
        UpdatePhase.refused => (
          'Update discarded',
          '${updater.message} Nothing was installed.',
          [
            action('dismiss', 'Dismiss', updater.dismiss),
            action('retry', 'Try again', updater.downloadAndInstall),
          ],
        ),
        UpdatePhase.failed => (
          'Update not installed',
          updater.message,
          [action('dismiss', 'Dismiss', updater.dismiss)],
        ),
      };
      if (title == null && body == null) return const SizedBox.shrink();
      final busy = updater.busy || updater.phase == UpdatePhase.checking;
      return Card(
        key: const ValueKey('update-panel'),
        margin: const EdgeInsets.only(top: 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Row(
                  children: [
                    const Icon(Icons.system_update_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        key: const ValueKey('update-title'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              if (body != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(body, key: const ValueKey('update-body')),
                ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: LinearProgressIndicator(
                    value:
                        updater.phase == UpdatePhase.downloading &&
                            release != null
                        ? updater.received / release.size
                        : null,
                  ),
                ),
              if (actions.isNotEmpty)
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
            ],
          ),
        ),
      );
    },
  );
}
