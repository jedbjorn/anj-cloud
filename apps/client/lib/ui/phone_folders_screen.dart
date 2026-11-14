import 'package:flutter/material.dart';

import '../core/app/controller.dart';
import '../core/ports/phone_folders.dart';

/// The one-screen explanation of All files access (spec #52 Permission and
/// Paused States), at pairing and after the update that brings phone
/// folders.
const phoneFoldersExplanation =
    'AnJ Cloud keeps Music, Videos and Documents in your phone\'s own '
    'folders so every app can use them. Android calls this All files access.';

/// The home screen's one attention line while the folders are paused.
const phoneFoldersPausedLine =
    'Music, Videos and Documents are paused: allow All files access';

/// The first line of "Apps with access" (spec #52 Settings Text).
const phoneFoldersAppsAccessLine =
    'Music, Videos and Documents are in your phone\'s own folders. Apps '
    'with media or file access can use them. The approvals below cover your '
    'other folders.';

/// The explanation screen: Allow opens the system setting for AnJ Cloud.
class PhoneFoldersScreen extends StatelessWidget {
  const PhoneFoldersScreen({super.key, required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Phone folders')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.folder_shared_outlined, size: 48),
          const SizedBox(height: 16),
          const Text(
            phoneFoldersExplanation,
            key: ValueKey('phone-folders-explanation'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton(
                key: const ValueKey('phone-folders-allow'),
                onPressed: () {
                  controller.phoneFoldersAsked = true;
                  controller.openAllFilesAccess();
                },
                child: const Text('Allow'),
              ),
              const SizedBox(width: 12),
              TextButton(
                key: const ValueKey('phone-folders-later'),
                onPressed: () => controller.phoneFoldersAsked = true,
                child: const Text('Not now'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The paused attention line with its action (and a move that could not
/// finish); nothing otherwise.
class PhoneFoldersNotice extends StatelessWidget {
  const PhoneFoldersNotice({super.key, required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final problem = controller.phoneFolderProblem;
    if (!controller.phoneFoldersPaused) {
      return problem == null ? const SizedBox.shrink() : Text(problem);
    }
    return Row(
      key: const ValueKey('phone-folders-paused'),
      children: [
        Icon(
          Icons.error_outline,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 6),
        const Expanded(child: Text(phoneFoldersPausedLine)),
        TextButton(
          key: const ValueKey('phone-folders-open-settings'),
          onPressed: controller.openAllFilesAccess,
          child: const Text('Allow'),
        ),
      ],
    );
  }
}

/// The storage area of settings (spec #52 Settings Text): each cloud folder
/// and the phone folder it is.
class PhoneFoldersPage extends StatelessWidget {
  const PhoneFoldersPage({super.key, required this.controller});
  final ClientController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Phone folders')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Music, Videos and Documents are kept in your phone\'s own '
              'folders in internal storage, where every app can use them.',
            ),
          ),
          for (final MapEntry(key: top, value: folder)
              in phoneFolderNames.entries)
            ListTile(
              key: ValueKey('phone-folder-$top'),
              leading: const Icon(Icons.folder_outlined),
              title: Text(top),
              subtitle: Text('Internal storage › $folder'),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: PhoneFoldersNotice(controller: controller),
          ),
        ],
      ),
    ),
  );
}
