import 'package:flutter/material.dart';

import '../core/app/controller.dart';

/// Opens immediately while the worker reads cloud metadata. The destination
/// and each source retain the identities observed before the choice.
Future<void> showMoveFiles(
  BuildContext context,
  ClientController controller,
  List<Map<String, dynamic>> entries, {
  String? job,
  int? fileId,
}) async {
  final choices = controller.documentsCommand('moveChoices', {
    'files': [
      for (final entry in entries)
        {
          'path': entry['cloudPath'] ?? entry['path'],
          'fileId': entry['fileId'],
          'selectionVersion': entry['selectionVersion'],
          'etag': entry['etag'],
        },
    ],
    'job': ?job,
    'fileId': ?fileId,
  });
  final folder = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Move to…'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder(
          future: choices,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text('${snapshot.error}');
            if (!snapshot.hasData)
              return const LinearProgressIndicator(
                semanticsLabel: 'Loading folders',
              );
            final folders =
                (snapshot.data!['folders'] as Map).keys.cast<String>().toList()
                  ..sort();
            return ListView.builder(
              shrinkWrap: true,
              itemCount: folders.length,
              itemBuilder: (context, i) {
                final path = folders[i];
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(path.isEmpty ? 'Library root' : path),
                  onTap: () => Navigator.pop(context, path),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (folder == null || !context.mounted) return;
  try {
    final plan = await choices;
    final result = await controller.documentsCommand('moveFiles', {
      'account': plan['account'],
      'files': plan['files'],
      'folder': folder,
      'parentId': (plan['folders'] as Map)[folder],
    });
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move results'),
        scrollable: true,
        content: Text((result['results'] as List).join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  } catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
  }
}
