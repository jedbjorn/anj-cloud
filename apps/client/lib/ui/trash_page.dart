import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/app/controller.dart';
import '../core/state/model.dart';
import 'layout.dart';
import 'library_view.dart';

/// "Moved to Trash" or "3 items moved to Trash" (spec #44 T1).
String movedToTrashText(int count) =>
    count == 1 ? 'Moved to Trash' : '$count items moved to Trash';

/// What one Undo did, in one sentence (spec #44 Undo).
String undoMessage(Map<String, dynamic> result) {
  final results = (result['results'] as List? ?? const []).cast<Map>();
  final failed = results.where((r) => r['result'] == 'failed').toList();
  final renamed = results.where((r) => r['result'] == 'renamed').toList();
  final back = results.length - failed.length;
  final parts = <String>[];
  if (back > 0 && renamed.isEmpty) {
    parts.add(back == 1 ? 'Restored.' : '$back items restored.');
  } else if (renamed.length == 1 && back == 1) {
    parts.add(
      'Restored as ${p.posix.basename(renamed.single['to'] as String)}: the name was taken.',
    );
  } else if (renamed.isNotEmpty) {
    parts.add(
      '$back items restored; ${renamed.length} under a new name because the name was taken.',
    );
  }
  if (failed.length == 1) {
    parts.add(
      "Couldn't restore ${p.posix.basename(failed.single['path'] as String)}: ${failed.single['message']}. It stays in Trash.",
    );
  } else if (failed.isNotEmpty) {
    parts.add(
      "Couldn't restore ${failed.length} items: ${failed.first['message']}. They stay in Trash.",
    );
  }
  return parts.join(' ');
}

/// "Deleted permanently in 3 days" (spec #44 Trash View).
String expiresText(int expiresMs, int nowMs) {
  final left = expiresMs - nowMs;
  if (left <= Duration.millisecondsPerDay) {
    return 'Deleted permanently within a day';
  }
  final days = (left / Duration.millisecondsPerDay).ceil();
  return 'Deleted permanently in $days days';
}

/// The Trash view (spec #44): everything deleted in the last `trash_days`
/// days, from any device, with Restore; Delete now and Empty Trash are the
/// only deletions that still ask.
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.controller, this.now});
  final ClientController controller;

  /// Test seam for the clock.
  final DateTime Function()? now;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  ClientController get controller => widget.controller;
  Map<String, dynamic>? _listing;
  String? _error;
  bool _busy = false;
  bool _selecting = false;
  final _selected = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  List<Map<String, dynamic>> get _entries =>
      ((_listing?['entries'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Future<void> _load() async {
    try {
      final listing = await controller.trash('list');
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _error = null;
        _selected.removeWhere((i) => i >= _entries.length);
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _say(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _say(await action());
    } catch (error) {
      _say('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _restore(Map<String, dynamic> entry, {bool device = false}) =>
      _run(() async {
        final result = await controller.trash(
          device ? 'restoreDevice' : 'restore',
          {
            if (!device) 'serverId': entry['serverId'],
            'deviceId': entry['deviceId'],
          },
        );
        final name = p.posix.basename(result['path'] as String);
        return result['renamed'] == true
            ? 'Restored as $name: the name was taken.'
            : 'Restored $name.';
      });

  int _size(List<Map<String, dynamic>> entries) =>
      entries.fold(0, (sum, e) => sum + (e['size'] as int? ?? 0));

  Future<bool> _confirm(String title, int count, int bytes) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(
          '${count == 1 ? '1 item' : '$count items'} (${sizeLabel(bytes)}) will be deleted permanently. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-trash-delete'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _deleteNow(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    if (!await _confirm('Delete now?', entries.length, _size(entries))) return;
    await _run(() async {
      final result = await controller.trash('delete', {
        'serverIds': [
          for (final e in entries)
            if (e['serverId'] != null) e['serverId'],
        ],
        'deviceIds': [
          for (final e in entries)
            if (e['deviceId'] != null) e['deviceId'],
        ],
      });
      setState(() {
        _selecting = false;
        _selected.clear();
      });
      final errors = (result['errors'] as List? ?? const []).cast<String>();
      return errors.isEmpty
          ? 'Deleted permanently.'
          : 'Some items were kept: ${errors.join(' ')}';
    });
  }

  Future<void> _empty() async {
    final entries = _entries;
    if (entries.isEmpty) return;
    if (!await _confirm('Empty Trash?', entries.length, _size(entries))) {
      return;
    }
    await _run(() async {
      final result = await controller.trash('empty');
      final errors = (result['errors'] as List? ?? const []).cast<String>();
      return errors.isEmpty ? 'Trash emptied.' : errors.join(' ');
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final compact = compactLayout(context);
    final note = _listing?['note'] as String?;
    final days = _listing?['trashDays'] as int? ?? 7;
    final deviceBytes = _listing?['deviceBytes'] as int? ?? 0;
    final now = (widget.now ?? DateTime.now)().millisecondsSinceEpoch;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '${_selected.length} selected' : 'Trash'),
        leading: _selecting
            ? IconButton(
                tooltip: 'Cancel selection',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
              )
            : null,
        actions: [
          if (_selecting)
            TextButton(
              key: const ValueKey('trash-delete-selected'),
              onPressed: _busy || _selected.isEmpty
                  ? null
                  : () => _deleteNow([
                      for (final i in _selected.toList()..sort()) entries[i],
                    ]),
              child: const Text('Delete now'),
            )
          else ...[
            if (entries.isNotEmpty)
              TextButton(
                key: const ValueKey('trash-select'),
                onPressed: _busy
                    ? null
                    : () => setState(() => _selecting = true),
                child: const Text('Select'),
              ),
            TextButton(
              key: const ValueKey('trash-empty'),
              onPressed: _busy || entries.isEmpty ? null : _empty,
              child: const Text('Empty Trash'),
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Deleted permanently after $days days.'
                '${deviceBytes > 0 ? " This device's trash: ${sizeLabel(deviceBytes)}." : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (note != null)
              Padding(
                key: const ValueKey('trash-note'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(note),
              ),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
            if (_listing == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_listing != null && entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Trash is empty')),
              ),
            for (var i = 0; i < entries.length; i++)
              _row(entries[i], i, compact: compact, now: now),
          ],
        ),
      ),
    );
  }

  Widget _row(
    Map<String, dynamic> entry,
    int index, {
    required bool compact,
    required int now,
  }) {
    final path = entry['path'] as String;
    final folder = p.posix.dirname(path);
    final onlyDevice = entry['onlyDevice'] == true;
    final both = entry['serverId'] != null && entry['deviceId'] != null;
    final details = [
      'In ${folder == '.' ? 'AnJ Cloud' : folder}',
      'Deleted ${formatLibraryDate((entry['deleted'] as int) ~/ 1000)}',
      sizeLabel(entry['size'] as int? ?? 0),
    ].join(' · ');
    return ListTile(
      key: ValueKey('trash:$path:${entry['deleted']}'),
      leading: _selecting
          ? Checkbox(
              value: _selected.contains(index),
              onChanged: (_) => _toggle(index),
            )
          : Icon(
              entry['kind'] == 'folder'
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
            ),
      title: Text(p.posix.basename(path), overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$details\n${expiresText(entry['expires'] as int, now)}'
        '${onlyDevice ? '\nOnly on this device' : ''}',
      ),
      isThreeLine: true,
      onTap: _selecting ? () => _toggle(index) : null,
      onLongPress: _selecting
          ? null
          : () => setState(() {
              _selecting = true;
              _selected.add(index);
            }),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (compact)
                  IconButton(
                    key: ValueKey('trash-restore:$path'),
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore),
                    onPressed: _busy ? null : () => _restore(entry),
                  )
                else
                  TextButton(
                    key: ValueKey('trash-restore:$path'),
                    onPressed: _busy ? null : () => _restore(entry),
                    child: const Text('Restore'),
                  ),
                PopupMenuButton<String>(
                  key: ValueKey('trash-menu:$path'),
                  tooltip: 'More',
                  enabled: !_busy,
                  onSelected: (value) => switch (value) {
                    'device' => _restore(entry, device: true),
                    _ => _deleteNow([entry]),
                  },
                  itemBuilder: (_) => [
                    if (both)
                      const PopupMenuItem(
                        value: 'device',
                        child: Text("Restore this device's copy"),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete now'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  void _toggle(int index) => setState(() {
    if (!_selected.remove(index)) _selected.add(index);
  });
}
