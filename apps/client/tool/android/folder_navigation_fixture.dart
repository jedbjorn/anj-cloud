// Synthetic provider metadata for emu_folder_navigation.py. No pairing, network
// or user files: only the real Android launcher, bridge and DocumentsProvider.
import 'package:anj_cloud/core/ports/documents.dart';
import 'package:anj_cloud/platform/android/android_documents.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class _Host extends ChangeNotifier implements DocumentsHost {
  @override
  bool get documentsReady => true;
  @override
  void Function(String from, String to)? onLocalRename;
  @override
  List<Map<String, dynamic>> get entries => [
    for (final path in [
      'Documents',
      'Navigation root marker',
      'Documents/Navigation target',
      'Documents/Navigation target/Target child',
    ])
      {
        'path': path,
        'kind': 'directory',
        'status': 'current local',
        'expectedPresent': true,
      },
  ];

  @override
  Future<Map<String, Object?>> documentsCommand(
    String op,
    Map<String, Object?> args,
  ) => throw StateError('Navigation must not issue a worker command: $op');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = await getApplicationSupportDirectory();
  AndroidDocuments.start(_Host(), profile.path);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final target in {
                'Open root fixture': '',
                'Open nested fixture': 'Documents/Navigation target',
              }.entries)
                TextButton(
                  onPressed: () async {
                    final opened = await AndroidLauncher().openDirectory(
                      '',
                      target.value,
                      '',
                    );
                    if (!opened) throw StateError('No folder handler');
                  },
                  child: Text(target.key),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
