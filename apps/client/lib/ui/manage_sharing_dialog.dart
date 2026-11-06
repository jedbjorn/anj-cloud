import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'library_view.dart';
import '../core/state/model.dart';
import '../core/gateway/sharing.dart';

/// One Manage sharing request (`load`, `create`, `update`, `remove`); in the
/// app, [AppController.sharing] through the worker and its pause gate.
typedef SharingCall = Future<Object?> Function(
  String op, {
  String? path,
  String? recipient,
  String? permission,
  String? share,
});

/// The top-level folders that can never be shared themselves (spec #34 P4,
/// decision #148); folders inside them can. The gateway refuses them too.
const privateFolders = {'Documents', 'Music', 'Videos'};

/// Whether a row's ⋮ menu offers "Manage sharing…" and, if so, why it is
/// disabled (spec #26). Only folders this account owns: not the root, not
/// `Shared` or anything in it, not a share made to this account or anything
/// in it wherever it is mounted (spec #34 P6), not synthetic or deleted
/// rows, and not the private `Documents`, `Music`, `Videos` (spec #34 P4)
/// unless one is already shared out, so a share made before the rule can
/// still be removed.
({bool offered, String? disabledReason}) manageSharingItem(
  Map<String, dynamic> entry,
  String? unavailable,
) {
  final path = entry['path'] as String? ?? '';
  if (entry['kind'] != 'directory' ||
      entry['synthetic'] == true ||
      path.isEmpty ||
      inSharedFolder(path) ||
      entry['inIncomingShare'] == true ||
      terminalDeletionStatuses.contains(entry['status']) ||
      (privateFolders.contains(path) && entry['sharedOut'] != true)) {
    return (offered: false, disabledReason: null);
  }
  if (entry['etag'] == null) {
    return (offered: true, disabledReason: 'Upload this folder first');
  }
  return (offered: true, disabledReason: unavailable);
}

/// "Delete everywhere" is not offered on an incoming share's top row
/// (Nextcloud would leave the share), nor inside a View only share. Whether
/// a folder under `Shared/` is an incoming mount comes from the engine
/// (`incomingMount`: incoming list or permissions, never position alone);
/// without that fact the position decides, the safe way.
bool offersDeleteEverywhere(Map<String, dynamic> entry) =>
    entry['incomingShare'] == null &&
    !(entry['incomingMount'] as bool? ??
        isIncomingMount(entry['path'] as String? ?? '')) &&
    entry['viewOnly'] != true;

/// Shows "Manage sharing — `folder`" for an owned folder (spec #26). Returns
/// true once every change was saved.
Future<bool?> showManageSharing(
  BuildContext context, {
  required String path,
  required SharingCall call,
}) => showDialog<bool>(
  context: context,
  builder: (context) => ManageSharingDialog(path: path, call: call),
);

class _Recipient {
  _Recipient(
    this.id,
    this.name, {
    this.shareId,
    this.saved,
    required this.chosen,
  });
  final String id;
  final String name;

  /// Null for a person added in this dialog and not saved yet.
  final String? shareId;

  /// The permission the server confirmed; null when not shared yet.
  final SharePermission? saved;
  SharePermission chosen;
  bool removed = false;

  /// Why the last Save could not apply this row's change.
  String? error;

  bool get changed => shareId == null ? !removed : removed || chosen != saved;
}

class ManageSharingDialog extends StatefulWidget {
  const ManageSharingDialog({
    super.key,
    required this.path,
    required this.call,
  });
  final String path;
  final SharingCall call;

  @override
  State<ManageSharingDialog> createState() => _ManageSharingDialogState();
}

class _ManageSharingDialogState extends State<ManageSharingDialog> {
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  List<HouseholdUser> _users = const [];
  final List<_Recipient> _rows = [];

  String get _folder => p.posix.basename(widget.path);

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _reason(Object error) =>
      error is CloudFailure ? error.message : '$error';

  /// Loads the server's state. [keep]: rows whose change failed keep the
  /// user's intent and its reason on top of what the server now holds.
  Future<void> _load({List<_Recipient> keep = const []}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await widget.call('load') as Map;
      final users = [
        for (final row in data['users'] as List) HouseholdUser.fromJson(row),
      ];
      final shares = [
        for (final row in data['shares'] as List) OutgoingShare.fromJson(row),
      ].where((share) => share.path == widget.path);
      final rows = <_Recipient>[
        for (final share in shares)
          _Recipient(
            share.recipientId,
            share.recipientName,
            shareId: share.shareId,
            saved: share.permission,
            chosen: share.permission,
          ),
      ];
      for (final failed in keep) {
        final current = rows.where((row) => row.id == failed.id).firstOrNull;
        if (current != null) {
          current
            ..removed = failed.removed
            ..chosen = failed.removed ? current.chosen : failed.chosen
            ..error = failed.error;
        } else if (!failed.removed) {
          rows.add(
            _Recipient(failed.id, failed.name, chosen: failed.chosen)
              ..error = failed.error,
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _users = users;
        _rows
          ..clear()
          ..addAll(rows);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _reason(error);
      });
    }
  }

  bool get _changed => _rows.any((row) => row.changed);

  List<HouseholdUser> get _addable => [
    for (final user in _users)
      if (!_rows.any((row) => row.id == user.id && !row.removed)) user,
  ];

  void _add(HouseholdUser user) => setState(() {
    final existing = _rows.where((row) => row.id == user.id).firstOrNull;
    if (existing != null) {
      existing.removed = false;
    } else {
      _rows.add(
        _Recipient(user.id, user.displayName, chosen: SharePermission.edit),
      );
    }
  });

  /// Removals, then permission changes, then additions; one request each.
  /// Nothing is reported as applied that the server did not confirm.
  Future<void> _save() async {
    setState(() => _saving = true);
    final failed = <_Recipient>[];
    Future<void> attempt(
      _Recipient row,
      Future<Object?> Function() request,
    ) async {
      try {
        await request();
      } on Object catch (error) {
        failed.add(row..error = _reason(error));
      }
    }

    for (final row
        in _rows.where((r) => r.removed && r.shareId != null).toList()) {
      await attempt(row, () => widget.call('remove', share: row.shareId));
    }
    for (final row
        in _rows
            .where(
              (r) => !r.removed && r.shareId != null && r.chosen != r.saved,
            )
            .toList()) {
      await attempt(
        row,
        () => widget.call(
          'update',
          share: row.shareId,
          permission: row.chosen.name,
        ),
      );
    }
    for (final row
        in _rows.where((r) => !r.removed && r.shareId == null).toList()) {
      await attempt(
        row,
        () => widget.call(
          'create',
          path: widget.path,
          recipient: row.id,
          permission: row.chosen.name,
        ),
      );
    }
    if (!mounted) return;
    if (failed.isEmpty) {
      Navigator.of(context).pop(true);
      return;
    }
    await _load(keep: failed);
    if (mounted) setState(() => _saving = false);
  }

  Widget _row(BuildContext context, _Recipient row) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('share-row:${row.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: row.removed
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                ),
              ),
              if (row.removed) ...[
                Text('Removed on Save', style: theme.textTheme.bodySmall),
                TextButton(
                  key: ValueKey('share-undo:${row.id}'),
                  onPressed: _saving
                      ? null
                      : () => setState(() => row.removed = false),
                  child: Text('Undo', semanticsLabel: 'Keep ${row.name}'),
                ),
              ] else ...[
                // One access level (decision #155): full access. A View only
                // share from before can be raised; nothing is downgraded.
                if (row.chosen == SharePermission.view) ...[
                  Text(
                    'View only',
                    key: ValueKey('share-access:${row.id}'),
                    style: theme.textTheme.bodySmall,
                  ),
                  TextButton(
                    key: ValueKey('share-upgrade:${row.id}'),
                    onPressed: _saving
                        ? null
                        : () =>
                              setState(() => row.chosen = SharePermission.edit),
                    child: Text(
                      'Give full access',
                      semanticsLabel: 'Give ${row.name} full access',
                    ),
                  ),
                ] else
                  Text(
                    row.saved == SharePermission.view
                        ? 'Full access on Save'
                        : 'Full access',
                    key: ValueKey('share-access:${row.id}'),
                    style: theme.textTheme.bodySmall,
                  ),
                IconButton(
                  key: ValueKey('share-remove:${row.id}'),
                  tooltip: 'Remove ${row.name}',
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          if (row.shareId == null) {
                            _rows.remove(row);
                          } else {
                            row.removed = true;
                          }
                        }),
                  icon: const Icon(Icons.close),
                ),
              ],
            ],
          ),
          if (row.error != null)
            Text(
              row.error!,
              key: ValueKey('share-error:${row.id}'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(semanticsLabel: 'Loading sharing'),
        ),
      );
    }
    final error = _loadError;
    if (error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error, key: const ValueKey('share-load-error')),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const ValueKey('share-retry'),
            onPressed: _load,
            child: const Text('Retry'),
          ),
        ],
      );
    }
    // Spec #34 P4: a private folder keeps this dialog only so a share made
    // before the rule can be removed; nobody new can be added.
    final private = privateFolders.contains(widget.path);
    final addable = private ? const <HouseholdUser>[] : _addable;
    final none = private
        ? 'Documents, Music and Videos are private'
        : _users.isEmpty
        ? 'No other household users yet'
        : 'Everyone in the household already has access';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Not shared with anyone.'),
          ),
        for (final row in _rows) _row(context, row),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: addable.isEmpty
              ? Tooltip(
                  message: none,
                  child: OutlinedButton.icon(
                    key: const ValueKey('share-add'),
                    onPressed: null,
                    icon: const Icon(Icons.person_add_alt),
                    label: Text(
                      'Add person',
                      semanticsLabel: 'Add person. $none',
                    ),
                  ),
                )
              : MenuAnchor(
                  menuChildren: [
                    for (final user in addable)
                      MenuItemButton(
                        key: ValueKey('share-add-user:${user.id}'),
                        onPressed: () => _add(user),
                        child: Text(user.displayName),
                      ),
                  ],
                  builder: (context, controller, _) => OutlinedButton.icon(
                    key: const ValueKey('share-add'),
                    onPressed: _saving
                        ? null
                        : () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add person'),
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Escape and Cancel discard; neither interrupts a Save in flight.
    canPop: !_saving,
    child: _dialog(context),
  );

  Widget _dialog(BuildContext context) => AlertDialog(
    title: Text('Manage sharing — $_folder'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(child: _body(context)),
    ),
    actions: [
      TextButton(
        key: const ValueKey('share-cancel'),
        onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('share-save'),
        onPressed: _loading || _saving || _loadError != null || !_changed
            ? null
            : _save,
        child: Text(_saving ? 'Saving…' : 'Save'),
      ),
    ],
  );
}
