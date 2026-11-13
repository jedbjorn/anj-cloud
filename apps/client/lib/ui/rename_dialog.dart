import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app/controller.dart';
import '../core/sync/name_rule.dart';

/// Renames a local item whose name cannot sync (spec #49 residual row). The rename is a worker action; the dialog never touches
/// the root. Pops with the new path.
class RenameDialog extends StatefulWidget {
  const RenameDialog({
    super.key,
    required this.controller,
    required this.path,
    this.siblings = const {},
  });
  final ClientController controller;
  final String path;

  /// Names already in the item's folder.
  final Set<String> siblings;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: p.posix.basename(widget.path));
  bool _busy = false;
  String? _error;

  String get _current => p.posix.basename(widget.path);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final name = value ?? '';
    if (name == _current) return 'Choose a different name.';
    final refused = renameRefusal(name);
    if (refused != null) return refused;
    if (widget.siblings.contains(name)) {
      return 'A file or folder already uses this name.';
    }
    return null;
  }

  Future<void> _rename() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await widget.controller.renameLocal(widget.path, _name.text);
      if (mounted) Navigator.pop(context, path);
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
    final why = NameRule.cloudCheck(_current);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text('Rename $_current'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "This name can't sync${why == null ? '' : ': ${why.reason}'}"
                  '. It stays on this device only.',
                  key: const ValueKey('rename-reason'),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('rename-name'),
                  controller: _name,
                  autofocus: true,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: 'New name'),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  onFieldSubmitted: (_) => _rename(),
                  validator: _validate,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const ValueKey('rename-error'),
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
            key: const ValueKey('confirm-rename'),
            onPressed: _busy ? null : _rename,
            child: Text(_busy ? 'Renaming…' : 'Rename'),
          ),
        ],
      ),
    );
  }
}
