import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ports/documents.dart';

/// The label of an approvable folder ('' is the whole library).
String folderLabel(String folder) =>
    folder.isEmpty ? 'All of AnJ Cloud' : folder;

/// How to add a folder in another app's own picker (A1: Android's picker
/// opens in shared storage, so the user opens its side menu first).
String addFolderSteps(String app, String folder) =>
    'In $app, choose its add-folder option. In the picker, open the side '
    'menu, choose AnJ Cloud${folder.isEmpty ? '' : ', open ${folderLabel(folder)}'}, '
    'then tap Use this folder and Allow.';

/// "Apps with access" (spec #28 A5, decision #127): the apps the user
/// approved for specific folders, read-only or read-write, with their live
/// status, and the apps that asked. Default: no app has access. The AnJ
/// Cloud provider enforces this list on every call.
class AppsAccessPage extends StatefulWidget {
  const AppsAccessPage({super.key, required this.access});
  final AppAccess access;
  @override
  State<AppsAccessPage> createState() => _AppsAccessPageState();
}

class _AppsAccessPageState extends State<AppsAccessPage> {
  AppAccess get access => widget.access;
  final Map<String, InstalledApp> _apps = {};
  String? _error;

  /// Single files apps keep (R1), as the platform last reported them.
  List<FileGrant> _files = const [];
  bool _loadingFiles = false;
  bool _filesAgain = false;

  @override
  void initState() {
    super.initState();
    access.addListener(_changed);
    unawaited(_describe());
    unawaited(_loadFiles());
  }

  Future<void> _loadFiles() async {
    if (_loadingFiles) {
      _filesAgain = true;
      return;
    }
    _loadingFiles = true;
    try {
      do {
        _filesAgain = false;
        try {
          final files = await access.fileGrants();
          if (!mounted) return;
          setState(() => _files = files);
          unawaited(_describe());
        } catch (_) {
          // Shown again at the next change; folder approvals still work.
        }
      } while (_filesAgain && mounted);
    } finally {
      _loadingFiles = false;
    }
  }

  @override
  void dispose() {
    access.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    unawaited(_describe());
    unawaited(_loadFiles());
  }

  Future<void> _describe() async {
    final wanted = {
      for (final a in access.approvals) a.package,
      for (final r in access.requests) r.package,
      for (final f in _files) ...f.packages,
    }.where((p) => !_apps.containsKey(p)).toList();
    if (wanted.isEmpty) return;
    try {
      final found = await access.describe(wanted);
      if (mounted) setState(() => _apps.addAll(found));
    } catch (_) {
      // Labels are a nicety; the package name is shown instead.
    }
  }

  String _label(String package) => _apps[package]?.label ?? package;

  Widget _icon(String package) {
    final icon = _apps[package]?.icon;
    return icon == null
        ? const Icon(Icons.apps)
        : Image.memory(icon, width: 40, height: 40, gaplessPlayback: true);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _approve({String? package, String? folder}) async {
    final result = await Navigator.of(context).push<_Approval>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            _ApprovePage(access: access, package: package, folder: folder),
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      () => access.approve(result.app.package, result.folder, result.mode),
    );
    _apps[result.app.package] = result.app;
    if (!mounted || _error != null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add the folder in ${result.app.label}'),
        content: Text(addFolderSteps(result.app.label, result.folder)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(access.openApp(result.app.package));
            },
            child: Text('Open ${result.app.label}'),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(AppApproval approval) async {
    final app = _label(approval.package);
    final folder = folderLabel(approval.folder);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke $app?'),
        content: Text(
          '$app can no longer open or change files in $folder. Files it '
          'already has open stay open until it closes them. Other apps keep '
          'their access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-revoke'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => access.revoke(approval.package, approval.folder));
    }
  }

  String _holders(FileGrant file) {
    final named = [for (final p in file.packages) _label(p)];
    final unnamed = file.holders - named.length;
    if (named.isEmpty) {
      return file.holders == 1
          ? 'Kept by an app'
          : 'Kept by ${file.holders} apps';
    }
    return 'Kept by ${named.join(', ')}'
        '${unnamed > 0 ? ' and ${unnamed == 1 ? 'another app' : '$unnamed other apps'}' : ''}';
  }

  Future<void> _revokeFile(FileGrant file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke access to ${file.name}?'),
        content: Text(
          '${_holders(file)}. After revoking, no app can open this file '
          'until someone picks it again. A copy an app already has open stays '
          'open until it closes it. Folder approvals are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-revoke-file'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => access.revokeFile(file.documentId));
      await _loadFiles();
    }
  }

  static String _status(AppApproval approval) {
    final open = approval.openFiles == 0
        ? ''
        : ' · ${approval.openFiles} ${approval.openFiles == 1 ? 'file' : 'files'} still open';
    return switch (approval.status) {
          ApprovalStatus.approved => 'Approved: add the folder in the app',
          ApprovalStatus.connected => 'Connected',
          ApprovalStatus.revoked => 'Revoked',
        } +
        open;
  }

  @override
  Widget build(BuildContext context) {
    final approvals = access.approvals;
    final requests = access.requests;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Apps with access')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'No app can open your AnJ Cloud files until you approve it here, '
            'for a folder you choose. Approving is not enough on its own: '
            'the app then adds that folder once through its own picker. '
            'Read and write on a folder also covers its subfolders, even one '
            'approved read only.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('approve-app'),
              onPressed: () => _approve(),
              icon: const Icon(Icons.add),
              label: const Text('Approve an app'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (requests.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Asked for access', style: theme.textTheme.titleSmall),
            for (final request in requests)
              Card(
                child: ListTile(
                  leading: _icon(request.package),
                  title: Text(_label(request.package)),
                  subtitle: Text(
                    'Tried to open ${folderLabel(request.folder)}',
                  ),
                  trailing: Wrap(
                    children: [
                      TextButton(
                        onPressed: () => _approve(
                          package: request.package,
                          folder: request.folder,
                        ),
                        child: const Text('Approve'),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: () => _run(
                          () => access.forget(request.package, request.folder),
                        ),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 20),
          Text('Approved apps', style: theme.textTheme.titleSmall),
          if (approvals.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No app has access.'),
            ),
          for (final approval in approvals)
            Card(
              key: ValueKey('approval-${approval.package}-${approval.folder}'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: _icon(approval.package),
                      title: Text(_label(approval.package)),
                      subtitle: Text(
                        '${folderLabel(approval.folder)} · '
                        '${approval.mode == AccessMode.write ? 'Read and write' : 'Read only'}\n'
                        '${_status(approval)}',
                      ),
                      isThreeLine: true,
                    ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      children: [
                        if (approval.status == ApprovalStatus.approved)
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Add the folder'),
                                content: Text(
                                  addFolderSteps(
                                    _label(approval.package),
                                    approval.folder,
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: const Text('Close'),
                                  ),
                                  FilledButton(
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                      unawaited(
                                        access.openApp(approval.package),
                                      );
                                    },
                                    child: const Text('Open app'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text('How to add'),
                          ),
                        if (approval.status == ApprovalStatus.revoked) ...[
                          TextButton(
                            onPressed: () => _run(
                              () => access.approve(
                                approval.package,
                                approval.folder,
                                approval.mode,
                              ),
                            ),
                            child: const Text('Approve again'),
                          ),
                          TextButton(
                            onPressed: () => _run(
                              () => access.forget(
                                approval.package,
                                approval.folder,
                              ),
                            ),
                            child: const Text('Remove'),
                          ),
                        ] else
                          // Named for screen readers: several rows have one.
                          Semantics(
                            container: true,
                            button: true,
                            excludeSemantics: true,
                            label:
                                'Revoke ${_label(approval.package)} for '
                                '${folderLabel(approval.folder)}',
                            onTap: () => _revoke(approval),
                            child: TextButton(
                              key: ValueKey(
                                'revoke-${approval.package}-${approval.folder}',
                              ),
                              onPressed: () => _revoke(approval),
                              child: const Text('Revoke'),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Single files', style: theme.textTheme.titleSmall),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Files you picked one at a time in another app, which it kept '
                'permission to open.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (final file in _files)
              Card(
                key: ValueKey('file-grant-${file.documentId}'),
                child: ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(file.name),
                  subtitle: Text(
                    '${file.write ? 'Read and write' : 'Read only'} · '
                    '${_holders(file)}',
                  ),
                  trailing: Semantics(
                    container: true,
                    button: true,
                    excludeSemantics: true,
                    label: 'Revoke file ${file.name}',
                    onTap: () => _revokeFile(file),
                    child: TextButton(
                      key: ValueKey('revoke-file-${file.documentId}'),
                      onPressed: () => _revokeFile(file),
                      child: const Text('Revoke'),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Approval {
  _Approval(this.app, this.folder, this.mode);
  final InstalledApp app;
  final String folder;
  final AccessMode mode;
}

/// Choose an app, a folder and read-only or read-write.
class _ApprovePage extends StatefulWidget {
  const _ApprovePage({required this.access, this.package, this.folder});
  final AppAccess access;
  final String? package;
  final String? folder;
  @override
  State<_ApprovePage> createState() => _ApprovePageState();
}

class _ApprovePageState extends State<_ApprovePage> {
  List<InstalledApp>? _apps;
  String? _loadError;
  InstalledApp? _app;
  late String? _folder = widget.folder;
  AccessMode _mode = AccessMode.read;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final apps = await widget.access.installedApps();
      var chosen = apps.where((a) => a.package == widget.package).firstOrNull;
      if (chosen == null && widget.package != null) {
        chosen = (await widget.access.describe([
          widget.package!,
        ]))[widget.package];
        chosen ??= InstalledApp(widget.package!, widget.package!);
      }
      if (mounted) {
        setState(() {
          _apps = apps;
          _app = chosen;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folders = widget.access.folders;
    final query = _search.text.trim().toLowerCase();
    final apps = (_apps ?? const <InstalledApp>[])
        .where(
          (a) =>
              query.isEmpty ||
              a.label.toLowerCase().contains(query) ||
              a.package.toLowerCase().contains(query),
        )
        .toList();
    final ready = _app != null && _folder != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Approve an app'),
        actions: [
          TextButton(
            key: const ValueKey('approve-confirm'),
            onPressed: ready
                ? () =>
                      Navigator.of(context)
                          .pop(_Approval(_app!, _folder!, _mode))
                : null,
            child: const Text('Approve'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('1. App', style: theme.textTheme.titleSmall),
          if (_app != null)
            ListTile(
              leading: _app!.icon == null
                  ? const Icon(Icons.apps)
                  : Image.memory(_app!.icon!, width: 40, height: 40),
              title: Text(_app!.label),
              subtitle: Text(_app!.package),
              trailing: TextButton(
                onPressed: () => setState(() => _app = null),
                child: const Text('Change'),
              ),
            )
          else if (_loadError != null)
            Text('Could not list apps: $_loadError')
          else if (_apps == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search apps',
              ),
              onChanged: (_) => setState(() {}),
            ),
            for (final app in apps)
              ListTile(
                key: ValueKey('app-${app.package}'),
                leading: app.icon == null
                    ? const Icon(Icons.apps)
                    : Image.memory(app.icon!, width: 40, height: 40),
                title: Text(app.label),
                subtitle: Text(app.package),
                onTap: () => setState(() => _app = app),
              ),
            if (apps.isEmpty) const Text('No matching app.'),
          ],
          const SizedBox(height: 16),
          Text('2. Folder', style: theme.textTheme.titleSmall),
          RadioGroup<String>(
            groupValue: _folder,
            onChanged: (value) => setState(() => _folder = value),
            child: Column(
              children: [
                for (final folder in folders)
                  RadioListTile<String>(
                    key: ValueKey('folder-$folder'),
                    value: folder,
                    title: Text(folderLabel(folder)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('3. Access', style: theme.textTheme.titleSmall),
          RadioGroup<AccessMode>(
            groupValue: _mode,
            onChanged: (value) => setState(() => _mode = value ?? _mode),
            child: const Column(
              children: [
                RadioListTile<AccessMode>(
                  key: ValueKey('mode-read'),
                  value: AccessMode.read,
                  title: Text('Read only'),
                  subtitle: Text('Open and play files'),
                ),
                RadioListTile<AccessMode>(
                  key: ValueKey('mode-write'),
                  value: AccessMode.write,
                  title: Text('Read and write'),
                  subtitle: Text('Also save, create, rename and delete'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
