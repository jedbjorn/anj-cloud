import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gateway/admin_api.dart';
import 'layout.dart';
import 'pairing_code_qr.dart';

/// The Admin section (spec #27): Users (each with its devices, spec #34
/// P8), Invitations, Settings, Health, Activity. Shared UI over
/// [AdminCall]; every rule is the
/// gateway's. Destructive actions show the server's own confirmation text;
/// Cancel sends nothing.
class AdminPage extends StatefulWidget {
  const AdminPage({
    super.key,
    required this.call,
    required this.onNotAdmin,
    required this.server,
    this.initial = AdminView.users,
  });
  final AdminCall call;

  /// A 403 `not-admin` from any call: the app hides Admin with a notice.
  final VoidCallback onNotAdmin;

  /// The canonical origin this admin device is currently paired with.
  final String server;
  final AdminView initial;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

enum AdminView {
  users('Users', Icons.people_outline),
  invitations('Invitations', Icons.qr_code_2_outlined),
  settings('Settings', Icons.tune_outlined),
  health('Health', Icons.monitor_heart_outlined),
  activity('Activity', Icons.history);

  const AdminView(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _AdminPageState extends State<AdminPage> {
  late AdminView _view = widget.initial;
  late final AdminClient _client = AdminClient(_guarded);
  bool _closing = false;

  Future<AdminResponse> _guarded(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = await widget.call(method, path, body: body);
    if (response.status == 403 && response.map['error'] == 'not-admin') {
      _notAdmin();
    }
    return response;
  }

  void _notAdmin() {
    if (_closing) return;
    _closing = true;
    widget.onNotAdmin();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Widget get _section => KeyedSubtree(
    key: ValueKey(_view),
    child: switch (_view) {
      AdminView.users => UsersView(client: _client, server: widget.server),
      AdminView.invitations => InvitationsView(
        client: _client,
        server: widget.server,
      ),
      AdminView.settings => SettingsView(client: _client),
      AdminView.health => HealthView(client: _client),
      AdminView.activity => ActivityView(client: _client),
    },
  );

  @override
  Widget build(BuildContext context) {
    if (compactLayout(context)) return _compact(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: Row(
        children: [
          _ScrollingRail(
            child: NavigationRail(
              selectedIndex: _view.index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (index) =>
                  setState(() => _view = AdminView.values[index]),
              destinations: [
                for (final view in AdminView.values)
                  NavigationRailDestination(
                    icon: Icon(view.icon),
                    label: Text(view.label),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _section),
        ],
      ),
    );
  }

  /// Phone (spec #28 Phone Layout, #108 Q11): the views in the rail's
  /// order and words as scrollable tabs under the app bar; the same views,
  /// actions and server confirmations.
  Widget _compact(BuildContext context) => DefaultTabController(
    length: AdminView.values.length,
    initialIndex: _view.index,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Admin'),
        bottom: _EdgeFade(
          child: TabBar(
            key: const ValueKey('admin-tabs'),
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            onTap: (index) => setState(() => _view = AdminView.values[index]),
            tabs: [
              for (final view in AdminView.values)
                Tab(
                  key: ValueKey('admin-tab:${view.name}'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(view.icon, size: 18),
                      const SizedBox(width: 8),
                      Text(view.label),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      body: SafeArea(top: false, child: _section),
    ),
  );
}

/// The server's confirmation, shown as is. Returns the typed text ('' when
/// nothing must be typed) or null on Cancel.
Future<String?> showAdminConfirmation(
  BuildContext context,
  ConfirmationPrompt prompt,
) => showDialog<String>(
  context: context,
  builder: (context) => _ConfirmDialog(prompt: prompt),
);

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({required this.prompt});
  final ConfirmationPrompt prompt;
  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _ready =>
      widget.prompt.typed == null || _typed.text == widget.prompt.typed;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: compactLayout(context),
    title: Text(widget.prompt.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.prompt.effect),
        if (widget.prompt.typed != null) ...[
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('admin-confirm-typed'),
            controller: _typed,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Type ${widget.prompt.typed} to confirm',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const ValueKey('admin-confirm-cancel'),
        // The safe choice has focus: Enter or Escape alone changes nothing.
        autofocus: widget.prompt.typed == null,
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('admin-confirm-ok'),
        onPressed: _ready
            ? () => Navigator.pop(
                context,
                widget.prompt.typed == null ? '' : _typed.text,
              )
            : null,
        child: const Text('Confirm'),
      ),
    ],
  );
}

/// Fades the scrollable Admin tabs at the end edge, so a cut-off tab reads
/// as "more this way" rather than as clipped.
class _EdgeFade extends StatelessWidget implements PreferredSizeWidget {
  const _EdgeFade({required this.child});
  final TabBar child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (bounds) {
      final fade = bounds.width <= 0
          ? 0.0
          : (24 / bounds.width).clamp(0.0, 1.0);
      return LinearGradient(
        begin: AlignmentDirectional.centerStart.resolve(
          Directionality.of(context),
        ),
        end: AlignmentDirectional.centerEnd.resolve(Directionality.of(context)),
        colors: const [Colors.black, Colors.black, Colors.transparent],
        stops: [0, 1 - fade, 1],
      ).createShader(bounds);
    },
    child: child,
  );
}

/// Loading, error and refresh shared by every section.
abstract class _LoadingState<T extends StatefulWidget> extends State<T> {
  AdminClient get client;
  Map<String, dynamic>? data;
  String? error;
  bool busy = false;

  Future<Map<String, dynamic>> fetch();

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    try {
      final next = await fetch();
      if (!mounted) return;
      setState(() {
        data = next;
        error = null;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() => error = '$failure');
    }
  }

  void notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// One mutation with the server's confirmation flow, then a refresh. A
  /// stale target refreshes the list and says so.
  Future<Map<String, dynamic>?> act(
    String method,
    String path,
    Map<String, Object?> body, {
    String? done,
  }) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      final result = await client.mutate(
        method,
        path,
        body,
        confirm: (prompt) => showAdminConfirmation(context, prompt),
      );
      if (result != null && done != null) notify(done);
      return result;
    } on AdminFailure catch (failure) {
      notify(failure.message);
      return null;
    } catch (failure) {
      notify('$failure');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
      await reload();
    }
  }

  Widget frame({
    required String title,
    required List<Widget> children,
    List<Widget> actions = const [],
  }) {
    final compact = compactLayout(context);
    final refresh = IconButton(
      tooltip: 'Refresh',
      onPressed: busy ? null : reload,
      icon: const Icon(Icons.refresh),
    );
    final heading = Text(title, style: Theme.of(context).textTheme.titleLarge);
    return ListView(
      padding: EdgeInsets.all(compact ? 16 : 20),
      children: [
        if (compact) ...[
          // Phone: the view's action goes under its title, never squeezed.
          Row(
            children: [
              Expanded(child: heading),
              refresh,
            ],
          ),
          if (actions.isNotEmpty)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
        ] else
          Row(
            children: [
              Expanded(child: heading),
              ...actions,
              refresh,
            ],
          ),
        const SizedBox(height: 12),
        if (error != null)
          _Notice(text: error!, icon: Icons.error_outline)
        else if (data == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(semanticsLabel: 'Loading'),
            ),
          )
        else
          ...children,
      ],
    );
  }
}

/// One admin list row: a [ListTile] in a card. On wide windows the actions
/// are its trailing buttons; on a phone they wrap under the text, end
/// aligned in the same order, so a long name or a large font never squeezes
/// them (spec #28 Phone Layout). [trailing] stays trailing in both.
Widget _adminRow(
  BuildContext context, {
  required Key key,
  Widget? leading,
  required Widget title,
  Widget? subtitle,
  Widget? trailing,
  List<Widget> actions = const [],
  Color? color,
  double? elevation,
}) {
  if (!compactLayout(context)) {
    return Card(
      color: color,
      elevation: elevation,
      child: ListTile(
        key: key,
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing:
            trailing ??
            switch (actions) {
              [] => null,
              [final only] => only,
              _ => Wrap(spacing: 8, children: actions),
            },
      ),
    );
  }
  return Card(
    color: color,
    elevation: elevation,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: key,
          leading: leading,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.icon});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: ListTile(leading: Icon(icon), title: Text(text)),
  );
}

String _when(Object? iso) {
  if (iso is! String) return 'never';
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return 'unknown';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

// Users ---------------------------------------------------------------------

class UsersView extends StatefulWidget {
  const UsersView({super.key, required this.client, required this.server});
  final AdminClient client;
  final String server;
  @override
  State<UsersView> createState() => _UsersViewState();
}

class _UsersViewState extends _LoadingState<UsersView> {
  @override
  AdminClient get client => widget.client;

  /// Users and their devices (spec #34 P8, decision #152): the same
  /// `/v1/admin/devices` list the Devices tab had, grouped by `uid` here.
  /// A failing devices request leaves the users and their actions in place;
  /// the expanded lists say the devices are unavailable.
  @override
  Future<Map<String, dynamic>> fetch() async {
    final devices = client
        .get('/v1/admin/devices')
        .then<Map<String, dynamic>>(
          (data) => {'devices': data['devices'] ?? const []},
          onError: (Object failure) => {'devicesError': '$failure'},
        );
    final users = await client.get('/v1/admin/users');
    return {...users, ...await devices};
  }

  List<Map<String, dynamic>> get users => [
    for (final row in (data?['users'] as List? ?? const []))
      Map<String, dynamic>.from(row as Map),
  ];

  List<Map<String, dynamic>> get devices => [
    for (final row in (data?['devices'] as List? ?? const []))
      Map<String, dynamic>.from(row as Map),
  ];

  /// Users whose device list is open; kept across refreshes.
  final Set<String> _open = {};

  Widget _devicesOf(String uid) {
    final own = [
      for (final device in devices)
        if (device['uid'] == uid) device,
    ];
    final failure = data?['devicesError'] as String?;
    return Padding(
      key: ValueKey('admin-user-devices:$uid'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failure != null)
            ListTile(
              key: ValueKey('admin-devices-error:$uid'),
              dense: true,
              leading: const Icon(Icons.error_outline),
              title: Text('Devices unavailable: $failure'),
            ),
          for (final device in own) _deviceTile(this, device),
          if (own.isEmpty && failure == null)
            const ListTile(
              dense: true,
              leading: Icon(Icons.info_outline),
              title: Text('No paired devices.'),
            ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => const _AddUserDialog(),
    );
    if (result == null) return;
    await act('POST', '/v1/admin/users', {
      'uid': result.$1,
      'display_name': result.$2,
    }, done: 'Added ${result.$2}.');
  }

  @override
  Widget build(BuildContext context) => frame(
    title: 'Users',
    actions: [
      FilledButton.icon(
        key: const ValueKey('admin-add-user'),
        onPressed: busy ? null : _add,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add user'),
      ),
    ],
    children: [
      for (final user in users)
        if (user['setup_incomplete'] == true)
          _adminRow(
            context,
            key: ValueKey('admin-user:${user['uid']}'),
            leading: const Icon(
              Icons.warning_amber_outlined,
              semanticLabel: 'Needs attention',
            ),
            title: Text('${user['display_name']} (${user['uid']})'),
            subtitle: const Text('Setup incomplete — add again to finish'),
            actions: [
              OutlinedButton(
                key: ValueKey('admin-finish-user:${user['uid']}'),
                onPressed: busy
                    ? null
                    : () => act('POST', '/v1/admin/users', {
                        'uid': user['uid'],
                        'display_name': user['display_name'],
                      }, done: 'Finished adding ${user['display_name']}.'),
                child: const Text('Finish setup'),
              ),
            ],
          )
        else
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  key: ValueKey('admin-user:${user['uid']}'),
                  onTap: () => _toggle(user['uid'] as String),
                  title: Text('${user['display_name']} (${user['uid']})'),
                  subtitle: Text(
                    [
                      user['enabled'] == true ? 'Enabled' : 'Disabled',
                      if (user['admin'] == true) 'Admin',
                      '${user['active_devices']} active '
                          '${user['active_devices'] == 1 ? 'device' : 'devices'}',
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        tooltip: 'Actions for ${user['display_name']}',
                        enabled: !busy,
                        onSelected: (choice) => _choose(choice, user),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'enabled',
                            child: Text(
                              user['enabled'] == true ? 'Disable' : 'Enable',
                            ),
                          ),
                          PopupMenuItem(
                            value: 'admin',
                            child: Text(
                              user['admin'] == true
                                  ? 'Remove admin'
                                  : 'Make admin',
                            ),
                          ),
                          if (user['enabled'] == true)
                            const PopupMenuItem(
                              value: 'invite',
                              child: Text('Invite a device'),
                            ),
                        ],
                      ),
                      IconButton(
                        key: ValueKey('admin-user-expand:${user['uid']}'),
                        tooltip: _open.contains(user['uid'])
                            ? 'Hide devices of ${user['display_name']}'
                            : 'Show devices of ${user['display_name']}',
                        onPressed: () => _toggle(user['uid'] as String),
                        icon: Icon(
                          _open.contains(user['uid'])
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_open.contains(user['uid']))
                  _devicesOf(user['uid'] as String),
              ],
            ),
          ),
      // Devices whose account is not listed (never expected): still shown,
      // so removing the Devices tab hides none.
      if (_unlisted.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            'Other devices',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final device in _unlisted) _deviceTile(this, device),
      ],
    ],
  );

  List<Map<String, dynamic>> get _unlisted {
    final uids = {for (final user in users) user['uid']};
    return [
      for (final device in devices)
        if (!uids.contains(device['uid'])) device,
    ];
  }

  void _toggle(String uid) => setState(() {
    if (!_open.remove(uid)) _open.add(uid);
  });

  Future<void> _choose(String choice, Map<String, dynamic> user) async {
    final uid = user['uid'] as String;
    switch (choice) {
      case 'enabled':
        final enable = user['enabled'] != true;
        await act('POST', '/v1/admin/users/$uid/enabled', {
          'enabled': enable,
          'expect': user['revision'],
        }, done: enable ? 'Enabled $uid.' : 'Disabled $uid.');
      case 'admin':
        final grant = user['admin'] != true;
        await act(
          'POST',
          '/v1/admin/users/$uid/admin',
          {'admin': grant, 'expect': user['revision']},
          done: grant ? '$uid is now an admin.' : '$uid is no longer an admin.',
        );
      case 'invite':
        await _createInvitation(
          context,
          this,
          users,
          server: widget.server,
          preset: uid,
        );
    }
  }
}

class _AddUserDialog extends StatefulWidget {
  const _AddUserDialog();
  @override
  State<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<_AddUserDialog> {
  final _uid = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _uid.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _valid =>
      // The server's one id rule (services/access/naming.py); it checks again.
      RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(_uid.text) &&
      _name.text.trim().isNotEmpty &&
      _name.text.trim().length <= 64;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: compactLayout(context),
    title: const Text('Add user'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('admin-user-name'),
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('admin-user-id'),
          controller: _uid,
          decoration: const InputDecoration(
            labelText: 'User id',
            helperText:
                'Starts with a letter; lowercase letters, digits and -; '
                'cannot change later',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('admin-user-save'),
        onPressed: _valid
            ? () => Navigator.pop(context, (_uid.text, _name.text.trim()))
            : null,
        child: const Text('Add'),
      ),
    ],
  );
}

// Devices -------------------------------------------------------------------

/// One device under its user (spec #34 P8): label, access, last seen, this
/// device, and Reissue / Revoke with the server's confirmations. A device
/// paired by code also shows the computer name and short key fingerprint its
/// new-device alert named (spec #35), so the alert leads to the right row.
/// On a phone the actions wrap under the text ([_adminRow], spec #28 A6).
Widget _deviceTile(_LoadingState state, Map<String, dynamic> device) {
  final name = device['label'] as String? ?? 'Device';
  final computer = device['computer_name'] as String?;
  final fingerprint = device['fingerprint_short'] as String?;
  final active = device['state'] == 'active';
  final busy = state.busy;
  return _adminRow(
    state.context,
    key: ValueKey('admin-device:${device['id']}'),
    elevation: 0,
    color: Theme.of(state.context).colorScheme.surfaceContainerLow,
    leading: const Icon(Icons.devices_other_outlined),
    title: Text(device['this_device'] == true ? '$name · This device' : name),
    subtitle: Text(
      [
        device['grant'] == 'write' ? 'Full access' : 'View only',
        active ? 'Active' : 'Revoked',
        'Last seen ${_when(device['last_seen'])}',
        'Certificate until ${_when(device['certificate_expires'])}',
        if (computer != null)
          "Computer '$computer'${fingerprint != null ? ' (fp $fingerprint)' : ''}",
      ].join(' · '),
    ),
    actions: [
      if (active) ...[
        OutlinedButton(
          key: ValueKey('admin-reissue:${device['id']}'),
          onPressed: busy
              ? null
              : () => state.act(
                  'POST',
                  '/v1/admin/devices/${device['id']}/reissue',
                  {'expect': device['revision']},
                  done: 'New certificate issued for $name.',
                ),
          child: const Text('Reissue'),
        ),
        OutlinedButton(
          key: ValueKey('admin-revoke:${device['id']}'),
          onPressed: busy
              ? null
              : () => state.act(
                  'POST',
                  '/v1/admin/devices/${device['id']}/revoke',
                  {'expect': device['revision']},
                  done: 'Revoked $name.',
                ),
          child: const Text('Revoke'),
        ),
      ],
    ],
  );
}

// Invitations ---------------------------------------------------------------

/// Create an invitation (user, grant, label) and show its code once with the
/// current admin device's [server], which manual pairing also needs.
Future<void> _createInvitation(
  BuildContext context,
  _LoadingState state,
  List<Map<String, dynamic>> users, {
  required String server,
  String? preset,
}) async {
  final request = await showDialog<Map<String, Object?>>(
    context: context,
    builder: (context) => _InviteDialog(users: users, preset: preset),
  );
  if (request == null || !context.mounted) return;
  final created = await state.act('POST', '/v1/admin/invitations', request);
  if (created == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _CodeDialog(created: created, server: server),
  );
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.users, this.preset});
  final List<Map<String, dynamic>> users;
  final String? preset;
  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  late String? _uid = widget.preset;
  String _grant = 'write';
  final _label = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: compactLayout(context),
    title: const Text('Invite a device'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('admin-invite-user'),
          initialValue: _uid,
          decoration: const InputDecoration(labelText: 'User'),
          items: [
            for (final user in widget.users)
              if (user['enabled'] == true)
                DropdownMenuItem(
                  value: user['uid'] as String,
                  child: Text('${user['display_name']} (${user['uid']})'),
                ),
          ],
          onChanged: (value) => setState(() => _uid = value),
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('admin-invite-grant'),
          initialValue: _grant,
          decoration: const InputDecoration(labelText: 'Access'),
          items: const [
            DropdownMenuItem(value: 'write', child: Text('Full access')),
            DropdownMenuItem(value: 'read', child: Text('View only')),
          ],
          onChanged: (value) => setState(() => _grant = value ?? 'write'),
        ),
        TextField(
          key: const ValueKey('admin-invite-label'),
          controller: _label,
          decoration: const InputDecoration(
            labelText: 'Label (optional), e.g. Alex’s phone',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('admin-invite-create'),
        onPressed: _uid == null
            ? null
            : () => Navigator.pop(context, {
                'uid': _uid,
                'grant': _grant,
                if (_label.text.trim().isNotEmpty) 'label': _label.text.trim(),
              }),
        child: const Text('Create code'),
      ),
    ],
  );
}

class _CodeDialog extends StatelessWidget {
  const _CodeDialog({required this.created, required this.server});
  final Map<String, dynamic> created;
  final String server;

  String get _code {
    final code = created['code'] as String? ?? '';
    return [
      for (var i = 0; i < code.length; i += 4)
        code.substring(i, (i + 4).clamp(0, code.length)),
    ].join('-');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: compactLayout(context),
    title: Text('Pairing code for ${created['uid']}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Server address', style: Theme.of(context).textTheme.titleSmall),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                server,
                key: const ValueKey('admin-invite-server'),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              key: const ValueKey('admin-invite-copy-server'),
              tooltip: 'Copy server address',
              onPressed: () => Clipboard.setData(ClipboardData(text: server)),
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Pairing code', style: Theme.of(context).textTheme.titleSmall),
        SelectableText(
          _code,
          key: const ValueKey('admin-invite-code'),
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 12),
        // Only the same code as a QR code, for the app's Scan QR code (#108 Q12).
        Center(
          child: PairingCodeQr(
            key: const ValueKey('admin-invite-qr'),
            code: created['code'] as String? ?? '',
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'For manual pairing, enter the server address and pairing code on '
          'the new device. Scanning the QR code supplies only the pairing code.',
        ),
        const SizedBox(height: 8),
        Text('Valid until ${_when(created['expires_at'])}. Shown only now.'),
        const SizedBox(height: 8),
        const Text(
          'Share this code only with the person setting up the device; '
          'it works once.',
        ),
      ],
    ),
    actions: [
      TextButton.icon(
        key: const ValueKey('admin-invite-copy-code'),
        onPressed: () => Clipboard.setData(ClipboardData(text: _code)),
        icon: const Icon(Icons.copy),
        label: const Text('Copy code'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}

class InvitationsView extends StatefulWidget {
  const InvitationsView({
    super.key,
    required this.client,
    required this.server,
  });
  final AdminClient client;
  final String server;
  @override
  State<InvitationsView> createState() => _InvitationsViewState();
}

class _InvitationsViewState extends _LoadingState<InvitationsView> {
  List<Map<String, dynamic>> _users = const [];

  @override
  AdminClient get client => widget.client;
  @override
  Future<Map<String, dynamic>> fetch() async {
    final users = await client.get('/v1/admin/users');
    _users = [
      for (final row in (users['users'] as List? ?? const []))
        Map<String, dynamic>.from(row as Map),
    ];
    return client.get('/v1/admin/invitations');
  }

  List<Map<String, dynamic>> _rows(String key) => [
    for (final row in (data?[key] as List? ?? const []))
      Map<String, dynamic>.from(row as Map),
  ];

  Future<void> _approve(Map<String, dynamic> row) async {
    final fingerprint = await showDialog<String>(
      context: context,
      builder: (context) => _ApproveDialog(row: row),
    );
    if (fingerprint == null) return;
    await act('POST', '/v1/admin/invitations/${row['id']}/approve', {
      'fingerprint': fingerprint,
      'expect': row['revision'],
    }, done: 'Approved ${row['label'] ?? 'the device'}.');
  }

  @override
  Widget build(BuildContext context) => frame(
    title: 'Invitations',
    actions: [
      FilledButton.icon(
        key: const ValueKey('admin-create-invitation'),
        onPressed: busy
            ? null
            : () => _createInvitation(
                context,
                this,
                _users,
                server: widget.server,
              ),
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
    ],
    children: [
      Text(
        'Waiting for approval',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      for (final row in _rows('pending'))
        _adminRow(
          context,
          key: ValueKey('admin-pending:${row['id']}'),
          title: Text('${row['label'] ?? 'New device'} for ${row['uid']}'),
          subtitle: Text(
            '${row['grant'] == 'write' ? 'Full access' : 'View only'} · '
            'until ${_when(row['expires_at'])}',
          ),
          actions: [
            FilledButton(
              key: ValueKey('admin-approve:${row['id']}'),
              onPressed: busy ? null : () => _approve(row),
              child: const Text('Approve'),
            ),
            OutlinedButton(
              key: ValueKey('admin-deny:${row['id']}'),
              onPressed: busy
                  ? null
                  : () => act(
                      'POST',
                      '/v1/admin/invitations/${row['id']}/deny',
                      {'expect': row['revision']},
                      done: 'Denied.',
                    ),
              child: const Text('Deny'),
            ),
          ],
        ),
      if (_rows('pending').isEmpty)
        const _Notice(text: 'No device is waiting.', icon: Icons.info),
      const SizedBox(height: 16),
      Text('Open codes', style: Theme.of(context).textTheme.titleMedium),
      for (final row in _rows('codes'))
        _adminRow(
          context,
          key: ValueKey('admin-code:${row['id']}'),
          title: Text('${row['label'] ?? 'Code'} for ${row['uid']}'),
          subtitle: Text('Unused · until ${_when(row['expires_at'])}'),
          actions: [
            OutlinedButton(
              key: ValueKey('admin-cancel:${row['id']}'),
              onPressed: busy
                  ? null
                  : () => act(
                      'POST',
                      '/v1/admin/invitations/${row['id']}/deny',
                      {'expect': row['revision']},
                      done: 'Code cancelled.',
                    ),
              child: const Text('Cancel code'),
            ),
          ],
        ),
      if (_rows('codes').isEmpty)
        const _Notice(text: 'No open codes.', icon: Icons.info),
    ],
  );
}

class _ApproveDialog extends StatefulWidget {
  const _ApproveDialog({required this.row});
  final Map<String, dynamic> row;
  @override
  State<_ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends State<_ApproveDialog> {
  // Never pre-filled: the admin types what the new device shows.
  final _fingerprint = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _fingerprint.dispose();
    super.dispose();
  }

  void _submit() {
    final value = normalizeFingerprint(_fingerprint.text);
    if (value == null) {
      setState(
        () => _error = 'Type all 64 characters of the fingerprint shown on the new device.',
      );
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: compactLayout(context),
    title: Text(
      'Approve ${widget.row['label'] ?? 'the new device'} '
      'for ${widget.row['uid']}?',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Read the fingerprint on the new device and type it here. If it '
          'does not match, nothing is approved.',
        ),
        TextField(
          key: const ValueKey('admin-fingerprint'),
          controller: _fingerprint,
          autofocus: true,
          minLines: 2,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: 'Fingerprint (64 characters)',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('admin-fingerprint-approve'),
        onPressed: _submit,
        child: const Text('Approve'),
      ),
    ],
  );
}

// Settings ------------------------------------------------------------------

class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.client});
  final AdminClient client;
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends _LoadingState<SettingsView> {
  final _mib = TextEditingController();
  String? _invalid;

  @override
  AdminClient get client => widget.client;
  @override
  Future<Map<String, dynamic>> fetch() async {
    final settings = await client.get('/v1/admin/settings');
    _mib.text = '${settings['upload_limit_mib']}';
    return settings;
  }

  @override
  void dispose() {
    _mib.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = int.tryParse(_mib.text.trim());
    final max = data?['max_mib'] as int? ?? 64;
    if (value == null || value < 1 || value > max) {
      setState(
        () => _invalid = value != null && value > max
            ? 'Above $max MiB needs large-transfer support.'
            : 'Choose a whole number from 1 to $max.',
      );
      return;
    }
    setState(() => _invalid = null);
    await act('PUT', '/v1/admin/settings', {
      'upload_limit_mib': value,
      'expect': data?['revision'],
    }, done: 'Upload limit changed to $value MiB.');
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      key: const ValueKey('admin-upload-limit'),
      controller: _mib,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Upload limit (MiB, 1–${data?['max_mib'] ?? 64})',
        errorText: _invalid,
      ),
      onSubmitted: (_) => _save(),
    );
    return frame(
      title: 'Settings',
      children: [
        Text(
          'Largest upload per file: ${data?['upload_limit_mib']} MiB. '
          'A change applies to uploads that start afterwards; devices learn it '
          'on their next request.',
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // On a phone the field takes the width left beside Save.
            if (compactLayout(context))
              Expanded(child: field)
            else
              SizedBox(width: 220, child: field),
            const SizedBox(width: 12),
            FilledButton(
              key: const ValueKey('admin-upload-limit-save'),
              onPressed: busy ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

// Health --------------------------------------------------------------------

class HealthView extends StatefulWidget {
  const HealthView({super.key, required this.client, this.interval});
  final AdminClient client;
  final Duration? interval;
  @override
  State<HealthView> createState() => _HealthViewState();
}

class _HealthViewState extends _LoadingState<HealthView> {
  Timer? _timer;

  @override
  AdminClient get client => widget.client;
  @override
  Future<Map<String, dynamic>> fetch() => client.get('/v1/admin/health');

  @override
  void initState() {
    super.initState();
    // Refreshed every 30 s while visible.
    _timer = Timer.periodic(
      widget.interval ?? const Duration(seconds: 30),
      (_) => unawaited(reload()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _testAlert() async {
    await act('POST', '/v1/admin/test-alert', {}, done: 'Test alert sent.');
  }

  static String _fact(Object? value) {
    if (value is! Map) return 'not configured';
    final state = value['state'];
    if (state == 'not-configured') return 'not configured';
    if (state == 'unavailable') return 'unavailable';
    return '';
  }

  Widget _card(String title, String text, {bool warn = false}) {
    // A source this server does not have is neither good nor bad news.
    final absent = text == 'not configured' || text == 'unavailable';
    return Card(
      key: ValueKey('admin-health:$title'),
      child: ListTile(
        leading: Icon(
          warn
              ? Icons.warning_amber_outlined
              : absent
              ? Icons.remove_circle_outline
              : Icons.check_circle_outline,
          semanticLabel: warn
              ? 'Needs attention'
              : absent
              ? 'Not configured'
              : 'OK',
        ),
        title: Text(title),
        subtitle: Text(text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gateway = Map<String, dynamic>.from(data?['gateway'] as Map? ?? {});
    final server = Map<String, dynamic>.from(data?['server'] as Map? ?? {});
    final fence = Map<String, dynamic>.from(
      gateway['write_fence'] as Map? ?? {},
    );
    final certificates = [
      for (final row
          in ((server['certificates'] as Map?)?['certificates'] as List? ??
              const []))
        Map<String, dynamic>.from(row as Map),
    ];
    final apps = [
      for (final row in ((server['pm2'] as Map?)?['apps'] as List? ?? const []))
        Map<String, dynamic>.from(row as Map),
    ];
    final backup = server['backup'] as Map?;
    final ddns = server['ddns'] as Map?;
    final disk = server['data_disk'] as Map?;
    return frame(
      title: 'Health',
      actions: [
        OutlinedButton.icon(
          key: const ValueKey('admin-test-alert'),
          onPressed: busy ? null : _testAlert,
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Send test alert'),
        ),
      ],
      children: [
        _card(
          'Server',
          gateway['ready'] == true ? 'Ready' : 'Not ready',
          warn: gateway['ready'] != true,
        ),
        if (server['state'] == 'unavailable')
          _card(
            'Admin service',
            server['message'] as String? ?? 'Unavailable',
            warn: true,
          ),
        _card(
          'Writes',
          fence['state'] == 'clear'
              ? 'Normal'
              : 'Paused (${fence['kind']}); recovery is a server procedure.',
          warn: fence['state'] != 'clear',
        ),
        for (final cert in certificates)
          _card(
            cert['name'] == 'issuer'
                ? 'Device certificate authority'
                : 'Server certificate',
            cert['state'] == 'missing'
                ? 'not configured'
                : 'Valid until ${_when(cert['expires_at'])} '
                      '(${cert['days_left']} days)',
            warn: cert['state'] == 'expiring' || cert['state'] == 'expired',
          ),
        _card(
          'Services',
          apps.isEmpty
              ? _fact(server['pm2']).ifEmpty('none listed')
              : apps
                    .map(
                      (app) =>
                          '${app['name']}: ${app['status']} '
                          '(${app['restarts']} restarts)',
                    )
                    .join(', '),
          warn: apps.any((app) => app['status'] != 'online'),
        ),
        _card(
          'Last backup',
          _fact(backup).isNotEmpty
              ? _fact(backup)
              : _when((backup?['last_success'] as Map?)?['finished_at']),
          warn: (backup?['hours_since_success'] as num? ?? 0) > 36,
        ),
        _card(
          'Address updates (DDNS)',
          _fact(ddns).isNotEmpty
              ? _fact(ddns)
              : '${ddns?['address'] ?? 'unknown'}, last ${_when(ddns?['last_success'])}',
        ),
        _card(
          'Data disk',
          _fact(disk).isNotEmpty
              ? _fact(disk)
              : '${disk?['used_percent']}% used',
          warn: (disk?['used_percent'] as num? ?? 0) > 90,
        ),
        _card(
          'Blocked pairing attempts (24 h)',
          '${gateway['enroll_blocks_24h'] ?? 0}',
          warn: (gateway['enroll_blocks_24h'] as num? ?? 0) > 0,
        ),
        _card(
          'Security reboot',
          _fact(server['reboot_pending']).isNotEmpty
              ? _fact(server['reboot_pending'])
              : ((server['reboot_pending'] as Map)['pending'] == true
                    ? 'Pending'
                    : 'None pending'),
          warn: (server['reboot_pending'] as Map?)?['pending'] == true,
        ),
        _card(
          'Emergency stop',
          _fact(server['emergency_stop']).isNotEmpty
              ? _fact(server['emergency_stop'])
              : ((server['emergency_stop'] as Map)['stopped'] == true
                    ? 'In place: the server is closed to the internet'
                    : 'Not in place'),
          warn: (server['emergency_stop'] as Map?)?['stopped'] == true,
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// Activity ------------------------------------------------------------------

class ActivityView extends StatefulWidget {
  const ActivityView({super.key, required this.client});
  final AdminClient client;
  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends _LoadingState<ActivityView> {
  final _entries = <Map<String, dynamic>>[];
  Object? _after;

  @override
  AdminClient get client => widget.client;
  @override
  Future<Map<String, dynamic>> fetch() async {
    final page = await client.get('/v1/admin/audit');
    _entries
      ..clear()
      ..addAll([
        for (final row in (page['entries'] as List? ?? const []))
          Map<String, dynamic>.from(row as Map),
      ]);
    _after = page['after'];
    return page;
  }

  Future<void> _older() async {
    try {
      final page = await client.get('/v1/admin/audit?after=$_after');
      setState(() {
        _entries.addAll([
          for (final row in (page['entries'] as List? ?? const []))
            Map<String, dynamic>.from(row as Map),
        ]);
        _after = page['after'];
      });
    } on AdminFailure catch (failure) {
      notify(failure.message);
    }
  }

  @override
  Widget build(BuildContext context) => frame(
    title: 'Activity',
    children: [
      for (final entry in _entries)
        ListTile(
          dense: true,
          title: Text(
            '${entry['action']} · ${entry['result']}'
            '${entry['target_uid'] != null ? ' · ${entry['target_uid']}' : ''}',
          ),
          subtitle: Text(
            '${_when(entry['time'])} · by ${entry['actor_uid'] ?? 'unknown'}',
          ),
        ),
      if (_entries.isEmpty)
        const _Notice(text: 'No admin activity yet.', icon: Icons.info),
      if (_after != null)
        TextButton(onPressed: _older, child: const Text('Load older')),
    ],
  );
}

/// The rail scrolls when the window is shorter than its destinations (a
/// 1366x768 screen at 150 % leaves about 440 logical pixels; a 13-inch
/// MacBook's top half about 430), and fills the height otherwise (spec #32
/// W6, spec #31 M5).
class _ScrollingRail extends StatelessWidget {
  const _ScrollingRail({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: IntrinsicHeight(child: child),
      ),
    ),
  );
}
