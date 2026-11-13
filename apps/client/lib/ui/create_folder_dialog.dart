import 'package:flutter/material.dart';

import '../core/app/controller.dart';
import '../core/state/model.dart';

/// Creation is exclusively a worker action. The dialog never accesses the root.
/// Parents are listed and the result is popped under their cloud spelling
/// (decision #193); the local path stays the worker's key.
class CreateFolderDialog extends StatefulWidget {
  const CreateFolderDialog({super.key, required this.controller});
  final ClientController controller;

  @override
  State<CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<CreateFolderDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  String _parent = '';
  Retention _retention = Retention.local;
  bool _busy = false;
  String? _error;

  /// Local path (the worker's key) -> cloud path (shown), by cloud path.
  late final Map<String, String> _parents;

  @override
  void initState() {
    super.initState();
    // Snapshot choices when opening. The worker rechecks the selected parent;
    // a failed operation must not remove its still-selected dropdown item.
    final parents = {
      for (final entry in widget.controller.entries)
        if (entry['kind'] == 'directory' &&
            entry['localDirectoryAvailable'] == true &&
            entry['conflict'] == null)
          entry['path'] as String:
              (entry['cloudPath'] ?? entry['path']) as String,
    };
    _parents = Map.fromEntries(
      parents.entries.toList()..sort((a, b) => a.value.compareTo(b.value)),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.createFolder(
        parent: _parent,
        name: _name.text,
        retention: _retention,
      );
      // The typed name is the cloud name, under the parent's cloud path.
      final shown = _parents[_parent];
      if (mounted) {
        Navigator.pop(
          context,
          shown == null ? _name.text : '$shown/${_name.text}',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Create folder'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('folder-name'),
                  controller: _name,
                  autofocus: true,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'Folder name'),
                  onFieldSubmitted: (_) => _create(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Enter a folder name.';
                    }
                    if (value == '.' ||
                        value == '..' ||
                        value.contains(RegExp(r'[/\\\x00]'))) {
                      return 'Use one folder name without path separators.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const ValueKey('folder-parent'),
                  initialValue: _parent,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Parent location',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('anj-cloud (root)'),
                    ),
                    for (final MapEntry(key: path, value: shown)
                        in _parents.entries)
                      DropdownMenuItem(
                        value: path,
                        child: Text(shown, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _parent = value ?? ''),
                ),
                const SizedBox(height: 16),
                const Text('Storage on this device'),
                const SizedBox(height: 8),
                SegmentedButton<Retention>(
                  segments: const [
                    ButtonSegment(value: Retention.local, label: Text('Local')),
                    ButtonSegment(value: Retention.cloud, label: Text('Cloud')),
                  ],
                  selected: {_retention},
                  onSelectionChanged: _busy
                      ? null
                      : (value) => setState(() => _retention = value.single),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Files inherit their containing folder’s storage choice.',
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const ValueKey('folder-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-create-folder'),
            onPressed: _busy ? null : _create,
            child: _busy
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Creating…'),
                    ],
                  )
                : const Text('Create'),
          ),
        ],
      ),
    );
  }
}
