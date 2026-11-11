import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/app/controller.dart';

/// Chooses the parent folder of the sync root and sets it up.
///
/// The dialog stays open until the root is set up: a refusal (a parent that
/// does not exist, an overlap, a folder the platform does not allow) is shown
/// in the dialog and stays there, where a snackbar over a closed dialog was
/// gone before it could be read. It owns its text controllers, which are
/// released with the route, after the closing animation (disposing them when
/// the dialog's future completed rebuilt the fields with disposed controllers).
class RootSetupDialog extends StatefulWidget {
  const RootSetupDialog({super.key, required this.controller});
  final ClientController controller;

  @override
  State<RootSetupDialog> createState() => _RootSetupDialogState();
}

class _RootSetupDialogState extends State<RootSetupDialog> {
  final _parent = TextEditingController();
  final _known = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _parent.dispose();
    _known.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final selected = await getDirectoryPath();
      if (selected != null && mounted) {
        setState(() {
          _parent.text = selected;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'The folder picker failed: $error');
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.configureRoot(
        _parent.text.trim(),
        knownRoots: _known.text
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .map((s) => s.trim())
            .toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeRootError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final automatic = widget.controller.automaticRoot;
    return AlertDialog(
      title: Text(
        automatic ? 'Use another folder' : 'Choose your anj-cloud root',
      ),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The app creates anj-cloud inside this parent folder. All regular files and nested folders there participate in synchronization.',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _parent,
                    onChanged: (_) => setState(() => _error = null),
                    decoration: const InputDecoration(
                      labelText: 'Parent directory',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Choose parent',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _busy ? null : _choose,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'The root always uses Local and cloud. Choose Cloud-only for individual folders in the app to free local space on this device. New content synchronizes automatically; child choices are preserved.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _known,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Known other sync roots (one per line)',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'This location is separate from my other synchronizers.',
              ),
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v ?? false),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  _error!,
                  key: const ValueKey('root-setup-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !_busy && _confirmed && _parent.text.trim().isNotEmpty
              ? _submit
              : null,
          child: Text(_busy ? 'Setting up…' : 'Use this root'),
        ),
      ],
    );
  }
}

/// A refused root as a sentence for the user. A [FileSystemException] reads
/// as its message and the path it names; anything else as its text.
@visibleForTesting
String describeRootError(Object error) {
  if (error is FileSystemException) {
    final path = error.path;
    final message = error.message;
    final osError = error.osError;
    final text = message.isNotEmpty ? message : (osError?.message ?? 'failed');
    return path == null || path.isEmpty || text.contains(path)
        ? text
        : '$text ($path)';
  }
  return error.toString();
}
