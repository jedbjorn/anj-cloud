import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../design/badge_palette.dart';
import 'add_files_flow.dart';
import 'admin_section.dart';
import '../core/app/add_files.dart';
import '../core/app/controller.dart';
import '../core/app/fetch_jobs.dart';
import '../core/sync/bulk_targets.dart';
import 'recovery_actions.dart';
import 'create_folder_dialog.dart';
import 'downloader_tab.dart';
import 'rename_dialog.dart';
import 'root_setup_dialog.dart';
import '../core/app/lifecycle.dart';
import '../core/ports/autostart.dart';
import '../core/update/desktop_updater.dart';
import '../core/ports/mobile_settings.dart';
import '../core/ports/documents.dart';
import 'apps_access_page.dart';
import 'library_toolbar.dart';
import 'library_view.dart';
import 'shortcuts.dart';
import 'trash_page.dart';
import 'library_entry_card.dart';
import 'library_list.dart';
import 'manage_sharing_dialog.dart';
import 'first_sync_screen.dart';
import 'layout.dart';
import 'pairing_form.dart';
import 'update_notice.dart';
import 'update_panel.dart';
import '../core/update/app_updater.dart';
import '../core/sync/sync_schedule.dart';
import '../core/sync/top_folders.dart';

String workingCopyDetails(Map<String, dynamic> entry) {
  if ((entry['workingCopies'] as List? ?? []).isEmpty) {
    return entry['workingCopy'] as String? ?? 'none';
  }
  final copies = editedCopies(entry);
  if (copies.isEmpty) return 'none';
  return copies
      .map(
        (copy) =>
            "${copy['path']} (${copy['size'] == null ? 'size unavailable' : '${copy['size']} bytes'})${copy['modified'] == null ? '' : '\nSaved: ${copy['modified']}'}",
      )
      .join('\n');
}

String localRecoveryDetails(Map<String, dynamic> entry) {
  final files = ((entry['localArtifacts'] as Map?)?['files'] as List? ?? [])
      .cast<Map>();
  return files
      .map(
        (f) =>
            "${f['path']} (${f['kind'] == null ? '' : '${f['kind']}, '}${f['size']} bytes)",
      )
      .join('\n');
}

enum _AppAction {
  pause,
  trash,
  autostart,
  wifiOnly,
  notifications,
  updates,
  appsAccess,
  quit,
}

class CloudApp extends StatelessWidget {
  const CloudApp({
    super.key,
    required this.controller,
    this.lifecycle,
    this.notices,
    this.autostart,
    this.updater,
    this.rootPicker = true,
    this.touchInput = false,
    this.autostartLabel = 'Start at login',
    this.mobile,
    this.androidUpdater,
    this.appAccess,
    this.addFiles,
  });
  final ClientController controller;
  final DesktopLifecycle? lifecycle;
  final LifecycleNotices? notices;
  final AutostartControl? autostart;

  /// The in-app updater (spec #37); null for builds that cannot update.
  final DesktopUpdater? updater;

  /// Desktop only (spec #28 Phone Layout): the root folder picker and the
  /// root's path. Android's root is fixed app-private storage.
  final bool rootPicker;

  /// The platform's input is touch (Android): rows open on tap and
  /// long-press for the icon colour. Window size never decides this.
  final bool touchInput;

  /// The switch's name: 'Start at login' on Linux, 'Background sync' on
  /// Android, where it is the same #40 choice (spec #28 Background Sync).
  final String autostartLabel;

  /// Phone-only settings (Android notifications); null on Linux.
  final MobileSettings? mobile;

  /// Android's in-app updater (spec #28 A7: APK signer pinned, the system
  /// installer); null on desktop, which uses [updater].
  final AppUpdater? androidUpdater;

  /// "Apps with access" (spec #28 A5, decision #127); Android only.
  final AppAccess? appAccess;

  /// Add files, Add folder and the Share sheet (spec #43); Android only.
  final AddFiles? addFiles;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AnJ Cloud',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245b69)),
      useMaterial3: true,
      extensions: const [BadgePalette.light],
    ),
    home: _withShares(
      ClientHome(
        controller: controller,
        lifecycle: lifecycle,
        notices: notices,
        autostart: autostart,
        updater: updater,
        rootPicker: rootPicker,
        touchInput: touchInput,
        autostartLabel: autostartLabel,
        mobile: mobile,
        androidUpdater: androidUpdater,
        appAccess: appAccess,
        addFiles: addFiles,
      ),
    ),
  );

  Widget _withShares(Widget home) {
    final adds = addFiles;
    return adds == null
        ? home
        : ShareReceiver(adds: adds, controller: controller, child: home);
  }
}

class ClientHome extends StatefulWidget {
  const ClientHome({
    super.key,
    required this.controller,
    this.lifecycle,
    this.notices,
    this.autostart,
    this.updater,
    this.rootPicker = true,
    this.touchInput = false,
    this.autostartLabel = 'Start at login',
    this.mobile,
    this.androidUpdater,
    this.appAccess,
    this.addFiles,
  });
  final ClientController controller;
  final DesktopLifecycle? lifecycle;
  final LifecycleNotices? notices;
  final AutostartControl? autostart;
  final DesktopUpdater? updater;
  final bool rootPicker;
  final bool touchInput;

  /// The switch's name: 'Start at login' on Linux, 'Background sync' on
  /// Android, where it is the same #40 choice (spec #28 Background Sync).
  final String autostartLabel;

  /// Phone-only settings (Android notifications); null on Linux.
  final MobileSettings? mobile;

  /// Android's in-app updater (spec #28 A7); null on desktop.
  final AppUpdater? androidUpdater;
  final AppAccess? appAccess;
  final AddFiles? addFiles;
  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> with TickerProviderStateMixin {
  ClientController get controller => widget.controller;
  late TabController _tabs;
  LibraryTab _active = LibraryTab.home;

  /// The Downloader (spec #42 F5): a fourth tab, present only while the
  /// server offers it. [_downloader] is whether it is the selected tab.
  late final FetchJobs _jobs = controller.fetchJobs;
  bool _hasDownloader = false;
  bool _downloader = false;
  final _fetchLinks = TextEditingController();

  /// The home's own focus. The Downloader's field goes away with its tab;
  /// focus then returns here, so the home's shortcuts keep working.
  final _homeFocus = FocusNode(debugLabel: 'home');
  AppLifecycleListener? _appState;

  TabController _newTabs(int length, int index) =>
      TabController(length: length, initialIndex: index, vsync: this)
        ..addListener(_tabChanged);

  void _tabChanged() {
    final downloader = _tabs.index >= LibraryTab.values.length;
    final tab = downloader ? _active : LibraryTab.values[_tabs.index];
    if (_active != tab || _downloader != downloader) {
      if (downloader && _selecting) _cancelSelection();
      if (_downloader && !downloader) _homeFocus.requestFocus();
      setState(() {
        _active = tab;
        _downloader = downloader;
        _clearSelection();
        _clearReveal();
      });
    }
    _showTab();
  }

  /// The job list is polled only while its tab is the selected one and on
  /// screen: the first-sync screen replaces the home, tabs included.
  void _showTab() => _jobs.setTabVisible(
    _downloader &&
        !(controller.firstSyncPending &&
            controller.pairingOptions.firstSync != null),
  );

  /// The tab appears and disappears with the server's answer. The selected
  /// library tab stays selected; a Downloader that went away returns to Home.
  void _fetchChanged() {
    final show = _jobs.availability == FetchAvailability.available;
    if (show == _hasDownloader || !mounted) return;
    final old = _tabs;
    final index = old.index < LibraryTab.values.length ? old.index : 0;
    if (_downloader) _homeFocus.requestFocus();
    setState(() {
      _hasDownloader = show;
      _downloader = false;
      _active = LibraryTab.values[index];
      _tabs = _newTabs(LibraryTab.values.length + (show ? 1 : 0), index);
    });
    _showTab();
    // After the tab bar has moved to the new controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  /// Desktop: the window is shown, not hidden in the tray.
  void _windowVisibility() => _jobs.setAppVisible(lifecycle!.visible);
  final _collapsed = {for (final tab in LibraryTab.values) tab: <String>{}};
  final _homeDirectories = <String>{};
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  LibraryPolicy _policy = LibraryPolicy.all;

  /// Rows a ranked chip (Recent, New) shows; More adds a page, Less resets.
  int _shown = libraryPageSize;
  bool _selecting = false;
  bool _bulkBusy = false;
  int _selectionEpoch = 0;
  BuildContext? _deleteDialog;
  final _selected = <String, Map<String, dynamic>>{};
  String? _revealedPath;
  String? _highlightedPath;
  Timer? _revealHighlightTimer;
  int _revealEpoch = 0;

  void _clearReveal() {
    _revealHighlightTimer?.cancel();
    _revealedPath = null;
    _highlightedPath = null;
  }

  void _showInFolder(
    String path, {
    String missing =
        'That file changed or is no longer in the library. Search again.',
  }) {
    if (_selecting) return;
    final exists = controller.entries.any(
      (entry) =>
          entry['path'] == path &&
          entry['kind'] == 'file' &&
          visibleInLibrary(entry),
    );
    if (!exists) {
      showError(context, missing);
      return;
    }
    _tabs.index = LibraryTab.home.index;
    setState(() {
      _clearSelection();
      _search.clear();
      _searchFocus.unfocus();
      final target = controller.entries.firstWhere(
        (entry) => entry['path'] == path,
      );
      final targetPolicy = target['effectiveRetention'] == 'cloud'
          ? LibraryPolicy.cloud
          : LibraryPolicy.local;
      if (_policy != LibraryPolicy.all && _policy != targetPolicy) {
        _policy = LibraryPolicy.all;
      }
      final parents = ancestors(path).toSet();
      _homeDirectories.addAll(parents);
      _collapsed[LibraryTab.home]!.removeAll(parents);
      _revealedPath = path;
      _highlightedPath = path;
      _revealHighlightTimer?.cancel();
      _revealHighlightTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _highlightedPath = null);
      });
      _revealEpoch++;
    });
  }

  void _cancelSelection() {
    final dialog = _deleteDialog;
    _deleteDialog = null;
    if (dialog != null && dialog.mounted) Navigator.pop(dialog, false);
    setState(() {
      _selecting = false;
      _selected.clear();
      _selectionEpoch++;
    });
  }

  void _clearSelection() {
    _selected.clear();
    _selectionEpoch++;
  }

  Future<void> _applyBulk(String action) async {
    final targets = _selected.values
        .map(
          (entry) => <String, dynamic>{
            'path': entry['path'],
            'kind': entry['kind'],
            'selectionVersion': entry['selectionVersion'],
          },
        )
        .toList();
    if (targets.isEmpty || _bulkBusy) return;
    final epoch = _selectionEpoch;
    if (action == 'delete') {
      // One step (spec #44): no confirmation; Undo and Trash replace it.
      setState(() => _bulkBusy = true);
      try {
        if (await _deleteToTrash(_selected.values.toList()) &&
            mounted &&
            epoch == _selectionEpoch) {
          setState(_clearSelection);
        }
      } finally {
        if (mounted) setState(() => _bulkBusy = false);
      }
      return;
    }
    if (!mounted || !_selecting || epoch != _selectionEpoch) {
      return;
    }
    setState(() => _bulkBusy = true);
    try {
      final result = await controller.bulkCommand(action, targets);
      if (!mounted) return;
      final errors = (result['errors'] as List? ?? []).join('\n');
      showError(
        context,
        '${result['accepted']} accepted; ${result['failed']} failed.${(result['covered'] as int? ?? 0) > 0 ? ' ${result['covered']} selected descendants covered by their folder.' : ''}${errors.isEmpty ? '' : '\n$errors'}',
      );
      if (epoch == _selectionEpoch) {
        setState(_clearSelection);
      }
    } catch (error) {
      if (mounted) showError(context, '$error');
    } finally {
      if (mounted) setState(() => _bulkBusy = false);
    }
  }

  /// Recover (spec #25): the newest copy, back into the sync folder.
  Future<void> _recover(Map<String, dynamic> entry) async {
    try {
      final result = await controller.bulkCommand('recover', [
        {'path': entry['path'], 'kind': entry['kind']},
      ]);
      if (mounted) {
        showError(context, recoverMessage(result, paused: controller.paused));
      }
    } catch (error) {
      if (mounted) showError(context, 'Could not recover: $error');
    }
  }

  /// Dismiss (spec #25): one confirmation, then the confirmed copies only.
  /// From Select mode the selection ends once the worker answers.
  Future<void> _dismiss(
    List<Map<String, dynamic>> entries, {
    bool selection = false,
  }) async {
    if (entries.isEmpty || (selection && _bulkBusy)) return;
    final epoch = _selectionEpoch;
    final yes = await confirmDismiss(
      context,
      entries,
      opened: selection ? (dialog) => _deleteDialog = dialog : null,
    );
    if (selection) _deleteDialog = null;
    if (!yes || !mounted) return;
    if (selection && (!_selecting || epoch != _selectionEpoch)) return;
    if (selection) setState(() => _bulkBusy = true);
    try {
      final result = await controller.bulkCommand(
        'dismiss',
        entries.map(dismissTarget).toList(),
      );
      if (!mounted) return;
      showError(context, dismissMessage(result));
      if (selection && epoch == _selectionEpoch) setState(_clearSelection);
    } catch (error) {
      if (mounted) showError(context, 'Could not dismiss: $error');
    } finally {
      if (selection && mounted) setState(() => _bulkBusy = false);
    }
  }

  DesktopLifecycle? get lifecycle => widget.lifecycle;
  AutostartState? _autostart;
  bool _autostartBusy = false;
  String? _autostartMessage;
  static const _autostartNotice = 'autostartAnnounced';

  Future<void> _loadAutostart() async {
    final manager = widget.autostart;
    if (manager == null) return;
    try {
      final state = await manager.status();
      if (!mounted) return;
      setState(() {
        _autostart = state;
        if (state.problem != null) {
          _autostartMessage = 'Start at login is off: ${state.problem}';
        }
      });
      _announceAutostart();
    } catch (_) {
      // Without manager status the toggle stays hidden.
    }
  }

  /// Announced once (decision #40), and only once someone can see it: a
  /// login start hidden in the tray keeps the notice for the first window.
  void _announceAutostart() {
    final state = _autostart;
    if (!mounted ||
        state == null ||
        state.problem != null ||
        !state.enabled ||
        state.source != 'default' ||
        (widget.notices?[_autostartNotice] ?? true) ||
        !(lifecycle?.visible ?? true)) {
      return;
    }
    widget.notices?.mark(_autostartNotice);
    setState(() {
      _autostartMessage =
          'AnJ Cloud now starts when you log in, hidden in the $desktopTrayName, '
          'so files keep syncing. To turn this off, open the ⋮ menu at the top '
          'right of this window and clear Start at login.';
    });
  }

  Future<void> _toggleAutostart() async {
    final manager = widget.autostart;
    final current = _autostart;
    if (manager == null || current == null || _autostartBusy) return;
    setState(() => _autostartBusy = true);
    try {
      final state = await manager.set(!current.enabled);
      if (mounted) {
        setState(() {
          _autostart = state;
          _autostartMessage = state.problem == null
              ? null
              : 'Start at login is off: ${state.problem}';
        });
      }
    } catch (error) {
      if (mounted) showError(context, 'Start at login was not changed: $error');
    } finally {
      if (mounted) setState(() => _autostartBusy = false);
    }
  }

  Future<bool> _confirmQuitWithoutTray() async {
    if (!mounted) return true;
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Closing stops sync'),
        content: Text(
          'This desktop has no $desktopTrayName, so AnJ Cloud cannot keep running '
          'in the background. Closing the window quits AnJ Cloud and sync '
          'stops until you open it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return quit ?? false;
  }

  @override
  void initState() {
    super.initState();
    lifecycle?.confirmQuitWithoutTray = _confirmQuitWithoutTray;
    lifecycle?.addListener(_announceAutostart);
    unawaited(_loadAutostart());
    _hasDownloader = _jobs.availability == FetchAvailability.available;
    _tabs = _newTabs(LibraryTab.values.length + (_hasDownloader ? 1 : 0), 0);
    _jobs.addListener(_fetchChanged);
    controller.addListener(_showTab);
    // Whether the app is on screen: the window on a desktop, the foreground
    // on Android (which has no window lifecycle).
    if (lifecycle != null) {
      lifecycle!.addListener(_windowVisibility);
      _windowVisibility();
    } else {
      final state = WidgetsBinding.instance.lifecycleState;
      _jobs.setAppVisible(state == null || state == AppLifecycleState.resumed);
      _appState = AppLifecycleListener(
        onStateChange: (state) =>
            _jobs.setAppVisible(state == AppLifecycleState.resumed),
      );
    }
  }

  @override
  void dispose() {
    lifecycle?.removeListener(_announceAutostart);
    lifecycle?.removeListener(_windowVisibility);
    _appState?.dispose();
    _jobs.removeListener(_fetchChanged);
    controller.removeListener(_showTab);
    _jobs.setTabVisible(false);
    _fetchLinks.dispose();
    _homeFocus.dispose();
    if (lifecycle?.confirmQuitWithoutTray == _confirmQuitWithoutTray) {
      lifecycle?.confirmQuitWithoutTray = null;
    }
    _revealHighlightTimer?.cancel();
    _tabs.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> rootSetup(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (context) => RootSetupDialog(controller: controller),
  );

  Future<void> finishEditing(
    BuildContext context,
    Map<String, dynamic> entry,
  ) async {
    final sessions = editedCopies(entry)
        .where((c) => c['id'] is String)
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
    if (sessions.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Finish editing ${entry['path']}'),
        scrollable: compactLayout(context),
        content: SelectableText(
          'Saved changes sync automatically while your editor is open. Close every editor using these copies, then confirm that the listed current files are your completed edit results. The app will verify uploaded content before releasing eligible temporary files. Busy, conflicting or uncertain copies stay recoverable. Storage policy stays unchanged.\n\n${workingCopyDetails(entry)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Editors closed — finish'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.command(
        'finishEditing',
        entry['path'] as String,
        sessions: sessions,
      );
    }
  }

  /// Remove opened copy (decision #184), after the user confirms every app
  /// using it is closed: an editor that read and closed the copy and saves
  /// later would write a file nothing syncs.
  Future<void> removeOpenedCopy(
    BuildContext context,
    Map<String, dynamic> entry,
  ) async {
    final sessions = [
      for (final copy in openedCopies(entry)) {'id': copy['id']},
    ];
    if (sessions.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove opened copy of ${entry['path']}'),
        scrollable: compactLayout(context),
        content: const Text(
          'Close every app using this copy first. Changes saved to it after removal will not sync. The file stays in the cloud.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('removeOpenedConfirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apps closed — remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      controller.command(
        'removeOpenedCopy',
        entry['path'] as String,
        sessions: sessions,
      );
    }
  }

  Future<void> pairing(BuildContext context) =>
      showPairing(context, controller);

  static IconData _statusIcon(SyncStatus status) => switch (status) {
    SyncStatus.upToDate => Icons.cloud_done_outlined,
    SyncStatus.syncing => Icons.cloud_sync_outlined,
    SyncStatus.paused => Icons.pause_circle_outline,
    SyncStatus.offline => Icons.cloud_off_outlined,
    SyncStatus.waiting => Icons.wifi_off_outlined,
    SyncStatus.attention => Icons.error_outline,
  };

  void showError(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Delete (spec #44): one step, no confirmation. The rows leave the
  /// library at once and the snackbar offers Undo and the Trash.
  Future<void> delete(BuildContext context, Map<String, dynamic> entry) =>
      _deleteToTrash([entry]);

  /// Returns true when the items were moved to Trash.
  Future<bool> _deleteToTrash(List<Map<String, dynamic>> entries) async {
    final targets = [
      for (final entry in entries)
        <String, dynamic>{
          'path': entry['path'],
          'kind': entry['kind'],
          'selectionVersion': entry['selectionVersion'],
        },
    ];
    if (targets.isEmpty) return false;
    try {
      final result = await controller.bulkCommand('delete', targets);
      if (!mounted) return false;
      final paths = (result['paths'] as List? ?? const []).cast<String>();
      if (paths.isEmpty || result['at'] is! int) {
        final errors = (result['errors'] as List? ?? const []).join('\n');
        showError(context, errors.isEmpty ? 'Nothing was deleted.' : errors);
        return false;
      }
      _showMovedToTrash(paths, result['at'] as int);
      return true;
    } catch (error) {
      if (mounted) showError(context, '$error');
      return false;
    }
  }

  /// "Moved to Trash · Undo": about 8 seconds, or until the next delete
  /// replaces it; View opens the Trash.
  void _showMovedToTrash(List<String> paths, int at) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('moved-to-trash'),
          duration: const Duration(seconds: 8),
          persist: false,
          content: Row(
            children: [
              Expanded(child: Text(movedToTrashText(paths.length))),
              TextButton(
                key: const ValueKey('moved-to-trash-view'),
                onPressed: () {
                  messenger.hideCurrentSnackBar();
                  _openTrash();
                },
                child: Text(
                  'View',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.inversePrimary,
                  ),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            key: const ValueKey('moved-to-trash-undo'),
            label: 'Undo',
            onPressed: () => unawaited(_undo(paths, at)),
          ),
        ),
      );
  }

  Future<void> _undo(List<String> paths, int at) async {
    try {
      final result = await controller.trash('undo', {'paths': paths, 'at': at});
      if (mounted) showError(context, undoMessage(result));
    } catch (error) {
      if (mounted) {
        showError(context, "Couldn't undo: $error. The items stay in Trash.");
      }
    }
  }

  void _openTrash() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => TrashPage(controller: controller)),
  );

  /// Rename for an item whose name is not allowed on other devices
  /// (decision #120).
  Future<void> renameEntry(BuildContext context, String path) async {
    final parent = p.posix.dirname(path);
    final siblings = {
      for (final entry in controller.entries)
        if (entry['path'] case final String other
            when other != path &&
                p.posix.dirname(other) == parent &&
                !terminalDeletionStatuses.contains(entry['status']))
          p.posix.basename(other),
    };
    final renamed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          RenameDialog(controller: controller, path: path, siblings: siblings),
    );
    if (renamed != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Renamed to ${p.posix.basename(renamed)}')),
      );
    }
  }

  Future<void> createFolder(BuildContext context) async {
    final path = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CreateFolderDialog(controller: controller),
    );
    if (path != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Created folder: $path')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      ?lifecycle,
      ?widget.updater,
      ?widget.mobile,
    ]),
    builder: (context, _) {
      // A first pairing was approved: choose folders before any sync
      // (decision #118). Returns at every start until confirmed.
      final firstSync = controller.pairingOptions.firstSync;
      if (controller.firstSyncPending && firstSync != null) {
        return Scaffold(
          appBar: AppBar(title: const Text('AnJ Cloud')),
          body: Column(
            children: [
              // A key that became unreadable before the choice: the reset,
              // not a screen that can only fail (#63 review F2).
              if (KeyUnavailableNotice.shown(controller))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: KeyUnavailableNotice(
                    controller: controller,
                    compact: true,
                  ),
                ),
              Expanded(
                child: FirstSyncScreen(
                  load: controller.firstSyncListing,
                  defaultChoice: firstSync,
                  onConfirm: controller.confirmFirstSync,
                  onPair: () => showPairing(context, controller),
                ),
              ),
            ],
          ),
        );
      }
      final adminNotice = controller.adminNotice;
      if (adminNotice != null) {
        controller.adminNotice = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(adminNotice)));
          }
        });
      }
      for (final entry in controller.entries) {
        final path = entry['path'] as String;
        final directories = [
          ...ancestors(path),
          if (entry['kind'] == 'directory') path,
        ];
        for (final directory in directories) {
          if (_homeDirectories.add(directory)) {
            _collapsed[LibraryTab.home]!.add(directory);
          }
        }
      }
      final syncing = activeSyncing(controller.entries, controller.syncing);
      final header = headerStatus(controller.status, syncing.length);
      final searching = _search.text.trim().isNotEmpty;
      final flat = libraryFlat(_policy, _search.text);
      final ranked = !searching && _policy.ranked;
      final allItems = libraryRows(
        controller.entries,
        _active,
        _collapsed[_active]!,
        policy: _policy,
        search: _search.text,
        syncing: syncing,
      );
      final items = ranked ? allItems.take(_shown).toList() : allItems;
      final more = ranked && allItems.length > items.length;
      final less = ranked && items.length > libraryPageSize;
      final visible = {for (final row in items) row.path: row.entry};
      final revealIndex = _revealedPath == null
          ? null
          : items.indexWhere(
              (row) => row.path == _revealedPath && row.entry['kind'] == 'file',
            );
      final selectedCount = _selected.length;
      _selected.removeWhere((path, selected) {
        final current = visible[path];
        return current == null ||
            current['synthetic'] == true ||
            current['kind'] != selected['kind'] ||
            current['selectionVersion'] != selected['selectionVersion'] ||
            !sameRecoveryCopies(current, selected) ||
            (dismissOnly(current) && !hasRecoveryCopies(current));
      });
      if (_selected.length != selectedCount) _selectionEpoch++;
      // Files, folders or a mix take a storage choice (spec #45 R4).
      final storageChoosable =
          _selected.isNotEmpty &&
          _selected.values.every(
            (entry) =>
                (entry['kind'] == 'directory' || entry['kind'] == 'file') &&
                !dismissOnly(entry),
          );
      // Documents, Music and Videos: never Cloud-only, never deleted
      // (spec #34 P7).
      final topSelected = _selected.keys.any(isTopFolder);
      // Recovery rows of completed deletions are selectable for Dismiss only.
      final dismissOnlySelected = _selected.values.any(dismissOnly);
      final allRecovery =
          _selected.isNotEmpty && _selected.values.every(hasRecoveryCopies);
      // Offered only once a recovery row is selected; the bar is unchanged
      // otherwise (it must fit narrow windows).
      final anyRecovery = _selected.values.any(hasRecoveryCopies);
      final filtering = libraryFiltersActive(_policy, _search.text);
      return CallbackShortcuts(
        bindings: {
          if (_selecting) AppShortcuts.cancel: _cancelSelection,
          if (!_downloader) AppShortcuts.search: _searchFocus.requestFocus,
        },
        child: Focus(
          focusNode: _homeFocus,
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              leading: Padding(
                padding: const EdgeInsets.all(8),
                child: Image.asset(
                  'assets/branding/harbor/icon-128.png',
                  semanticLabel: 'AnJ Cloud cloud seal',
                ),
              ),
              // A narrow phone at a large font shrinks the name to fit
              // beside the actions instead of cutting it off.
              title: compactWidth(context)
                  ? const FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text('AnJ Cloud'),
                    )
                  : const Text('AnJ Cloud'),
              actions: [
                // Spec #27: only for an account holding the admin role.
                if (controller.isAdmin)
                  _AppBarAction(
                    key: const ValueKey('open-admin'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AdminPage(
                          call: controller.admin,
                          onNotAdmin: controller.adminRoleRemoved,
                          server: controller.serverOrigin!,
                        ),
                      ),
                    ),
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Admin',
                  ),
                _AppBarAction(
                  key: const ValueKey('open-pairing'),
                  onPressed: () => pairing(context),
                  icon: Icons.devices,
                  label: controller.pairingState == 'paired'
                      ? 'Device pairing'
                      : 'Pair device',
                ),
                // Phone-only menu entries (spec #28), after Pause sync: A4's
                // Background sync switch, Wi-Fi setting and notifications,
                // A5's "Apps with access", A7's update check.
                PopupMenuButton<_AppAction>(
                  tooltip: 'AnJ Cloud menu',
                  onSelected: (value) {
                    switch (value) {
                      case _AppAction.pause:
                        controller.setPaused(!controller.paused);
                      case _AppAction.trash:
                        _openTrash();
                      case _AppAction.appsAccess:
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                AppsAccessPage(access: widget.appAccess!),
                          ),
                        );
                      case _AppAction.autostart:
                        unawaited(_toggleAutostart());
                      case _AppAction.wifiOnly:
                        controller.setNetworkPolicy(
                          controller.networkPolicy == 'wifi' ? 'any' : 'wifi',
                        );
                      case _AppAction.notifications:
                        unawaited(widget.mobile?.openNotificationSettings());
                      case _AppAction.updates:
                        unawaited(widget.androidUpdater?.check(manual: true));
                      case _AppAction.quit:
                        unawaited(lifecycle?.quit());
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _AppAction.pause,
                      child: Text(
                        controller.paused ? 'Resume sync' : 'Pause sync',
                      ),
                    ),
                    const PopupMenuItem(
                      key: ValueKey('open-trash'),
                      value: _AppAction.trash,
                      child: Text('Trash'),
                    ),
                    if (widget.autostart != null && _autostart != null)
                      CheckedPopupMenuItem(
                        value: _AppAction.autostart,
                        checked: _autostart!.enabled,
                        enabled: !_autostartBusy,
                        child: Text(widget.autostartLabel),
                      ),
                    // Decision #108 Q4: checked is "Wi-Fi only" (the
                    // default), cleared is "Wi-Fi or mobile data".
                    if (controller.networkPolicy != null)
                      CheckedPopupMenuItem(
                        value: _AppAction.wifiOnly,
                        checked: controller.networkPolicy == 'wifi',
                        child: const Text('Transfer files on Wi-Fi only'),
                      ),
                    if (widget.mobile != null &&
                        !widget.mobile!.notificationsAllowed)
                      const PopupMenuItem(
                        value: _AppAction.notifications,
                        child: Text('Notifications are off: allow'),
                      ),
                    if (widget.appAccess != null)
                      const PopupMenuItem(
                        key: ValueKey('open-apps-access'),
                        value: _AppAction.appsAccess,
                        child: Text('Apps with access'),
                      ),
                    if (widget.androidUpdater != null)
                      PopupMenuItem(
                        value: _AppAction.updates,
                        enabled: !widget.androidUpdater!.busy,
                        child: const Text('Check for updates'),
                      ),
                    if (lifecycle != null)
                      const PopupMenuItem(
                        value: _AppAction.quit,
                        child: Text('Quit AnJ Cloud'),
                      ),
                  ],
                ),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, body) {
                final compact = compactLayout(context);
                final short =
                    MediaQuery.sizeOf(context).height < compactHeightBreakpoint;
                final tabLabels = [
                  'Home',
                  'Editing',
                  'Conflict',
                  if (_hasDownloader) 'Downloader',
                ];
                // Three tabs lay out as they always have.
                final tabLayout = _hasDownloader
                    ? homeTabLayout(context, tabLabels, body.maxWidth)
                    : (scrollable: false, labelPadding: null);
                final top = <Widget>[
                  if (KeyUnavailableNotice.shown(controller))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: KeyUnavailableNotice(
                        controller: controller,
                        compact: true,
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    padding: compact
                        ? const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          )
                        : const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.rootPicker) ...[
                          Row(
                            children: [
                              const Icon(Icons.folder_outlined),
                              const SizedBox(width: 12),
                              Expanded(
                                child: SelectableText(
                                  controller.root ??
                                      (controller.settingUpRoot
                                          ? 'Creating your anj-cloud folder…'
                                          : controller.rootProblem ??
                                                'No local root selected'),
                                  key: const ValueKey('root-line'),
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              // Spec #34 P1: with an automatic root the
                              // picker is the advanced choice, offered when
                              // it was refused.
                              if (controller.root == null &&
                                  !controller.settingUpRoot)
                                FilledButton(
                                  onPressed: () => rootSetup(context),
                                  child: Text(
                                    controller.automaticRoot
                                        ? 'Use another folder'
                                        : 'Choose root',
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        Row(
                          children: [
                            Icon(_statusIcon(header.status), size: 18),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                header.label,
                                key: const ValueKey('sync-status'),
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          lifecycle?.quitting ?? false
                              ? 'Quitting: stopping sync safely...'
                              : controller.message,
                        ),
                        if (controller.secretsUnavailable != null &&
                            !(lifecycle?.quitting ?? false))
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const ValueKey('retry-secrets'),
                              onPressed: () =>
                                  unawaited(controller.retrySecrets()),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Retry'),
                            ),
                          ),
                        if (controller.folderMessage != null)
                          Text(controller.folderMessage!),
                        if (controller.certificateWarning != null)
                          Text(controller.certificateWarning!),
                        if (lifecycle?.note != null) Text(lifecycle!.note!),
                        if (widget.androidUpdater != null)
                          UpdatePanel(updater: widget.androidUpdater!),
                        if (widget.updater?.enabled ?? false)
                          UpdateNotice(updater: widget.updater!),
                        if (_autostartMessage != null)
                          Row(
                            children: [
                              Expanded(child: Text(_autostartMessage!)),
                              TextButton(
                                onPressed: () =>
                                    setState(() => _autostartMessage = null),
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  TabBar(
                    controller: _tabs,
                    isScrollable: tabLayout.scrollable,
                    tabAlignment: tabLayout.scrollable
                        ? TabAlignment.start
                        : null,
                    labelPadding: tabLayout.labelPadding,
                    tabs: [for (final label in tabLabels) Tab(text: label)],
                  ),
                  // The library's filters and search do not apply to the
                  // Downloader.
                  if (!_downloader)
                    LibraryToolbar(
                      policy: _policy,
                      onPolicyChanged: (value) => setState(() {
                        if (_policy != value) {
                          _clearSelection();
                          _shown = libraryPageSize;
                        }
                        _policy = value;
                        _clearReveal();
                      }),
                      search: _search,
                      searchFocus: _searchFocus,
                      onSearchChanged: (_) => setState(() {
                        _clearSelection();
                        _clearReveal();
                      }),
                      selecting: _selecting,
                      onEscape: _selecting ? _cancelSelection : null,
                      onSelect: () {
                        if (_selecting) {
                          _cancelSelection();
                        } else {
                          setState(() {
                            _selecting = true;
                            _selectionEpoch++;
                          });
                        }
                      },
                      onCreateFolder: controller.canCreateFolder
                          ? () => createFolder(context)
                          : null,
                    ),
                ];
                final selection = <Widget>[
                  if (_selecting)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '${_selected.length} selected',
                            key: const ValueKey('selection-count'),
                            semanticsLabel:
                                '${_selected.length} items selected',
                          ),
                          TextButton(
                            onPressed: _selected.isEmpty
                                ? null
                                : () => setState(_clearSelection),
                            child: const Text('Clear selection'),
                          ),
                          FilledButton(
                            key: const ValueKey('bulk-local'),
                            onPressed: storageChoosable && !_bulkBusy
                                ? () => _applyBulk('local')
                                : null,
                            child: const Text('Local and Cloud'),
                          ),
                          FilledButton(
                            key: const ValueKey('bulk-cloud'),
                            onPressed:
                                storageChoosable && !topSelected && !_bulkBusy
                                ? () => _applyBulk('cloud')
                                : null,
                            child: const Text('Cloud Only'),
                          ),
                          FilledButton(
                            key: const ValueKey('bulk-delete'),
                            onPressed:
                                _selected.isNotEmpty &&
                                    !dismissOnlySelected &&
                                    !topSelected &&
                                    !_bulkBusy
                                ? () => _applyBulk('delete')
                                : null,
                            child: const Text('Delete Everywhere'),
                          ),
                          if (anyRecovery)
                            FilledButton(
                              key: const ValueKey('bulk-dismiss'),
                              onPressed: allRecovery && !_bulkBusy
                                  ? () => _dismiss(
                                      _selected.values.toList(),
                                      selection: true,
                                    )
                                  : null,
                              child: const Text('Dismiss'),
                            ),
                          if (dismissOnlySelected && !allRecovery)
                            const Text(
                              'Recovery copies can only be dismissed; select them on their own.',
                            ),
                        ],
                      ),
                    ),
                ];
                final Widget list = _downloader
                    ? TickerMode(
                        // Hidden in the tray: no progress bar animates.
                        enabled: lifecycle?.visible ?? true,
                        child: DownloaderTab(
                          jobs: _jobs,
                          links: _fetchLinks,
                          touchInput: widget.touchInput,
                          onShowInFolder: (path) => _showInFolder(
                            path,
                            missing: 'That file is not in the library yet. It appears after the next sync.',
                          ),
                        ),
                      )
                    : items.isEmpty
                    ? Center(
                        child: Text(
                          controller.root == null
                              // Android sets its own root at start.
                              ? widget.rootPicker
                                    ? 'Choose a root, then pair this device.'
                                    : 'Files will appear here after a complete scan.'
                              : filtering
                              ? searching
                                    ? 'No files match your search.'
                                    : ranked
                                    ? 'No files yet.'
                                    : 'No items match your storage filter.'
                              : switch (_active) {
                                  LibraryTab.home => 'Files will appear here after a complete scan.',
                                  LibraryTab.editing =>
                                    'No editor sessions or pending completion.',
                                  LibraryTab.conflict =>
                                    'No unresolved conflicts.',
                                },
                        ),
                      )
                    : LibraryList(
                        // A new chip starts at the top of its list.
                        key: ValueKey(
                          'library-list:$_revealEpoch:$_revealedPath:${_policy.name}',
                        ),
                        revealIndex: revealIndex,
                        // Hidden in the tray: no row animates.
                        animate: lifecycle?.visible ?? true,
                        itemCount: items.length + (more || less ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == items.length) {
                            return _RankedPager(
                              onMore: more
                                  ? () => setState(
                                      () => _shown += libraryPageSize,
                                    )
                                  : null,
                              onLess: less
                                  ? () =>
                                        setState(() => _shown = libraryPageSize)
                                  : null,
                            );
                          }
                          final row = items[index];
                          final entry = row.entry;
                          final path = entry['path'] as String;
                          final file = entry['kind'] == 'file';
                          final unsupported = entry['kind'] == 'unsupported';
                          final directory = row.directory;
                          final collapsed =
                              !filtering && _collapsed[_active]!.contains(path);
                          final confirmable = editedCopies(entry)
                              .any((copy) => copy['id'] is String);
                          return LibraryEntryCard(
                            touchInput: widget.touchInput,
                            key: ValueKey('row:$path'),
                            selecting: _selecting,
                            flat: flat,
                            revealed:
                                path == _highlightedPath && revealIndex != -1,
                            onShowInFolder: file && flat && !_selecting
                                ? () => _showInFolder(path)
                                : null,
                            selected: _selected.containsKey(path),
                            onSelect:
                                entry['synthetic'] == true ||
                                    unsupported ||
                                    (dismissOnly(entry) &&
                                        !hasRecoveryCopies(entry)) ||
                                    path.isEmpty ||
                                    path == '.' ||
                                    path == '/'
                                ? null
                                : () => setState(() {
                                    if (_selected.remove(path) == null) {
                                      _selected[path] =
                                          Map<String, dynamic>.from(entry);
                                    }
                                    _selectionEpoch++;
                                  }),
                            row: row,
                            collapsed: collapsed,
                            showPath:
                                _active != LibraryTab.home ||
                                filtering ||
                                path == _revealedPath,
                            color: controller.iconColors[path],
                            onColorChanged: (color) =>
                                controller.setIconColor(path, color),
                            onToggle: filtering
                                ? null
                                : () => setState(() {
                                    if (collapsed) {
                                      _collapsed[_active]!.remove(path);
                                    } else {
                                      _collapsed[_active]!.add(path);
                                    }
                                  }),
                            onOpen: unsupported
                                ? null
                                : () => controller.command(
                                    directory ? 'openDirectory' : 'open',
                                    path,
                                  ),
                            onRename: entry['nameRefused'] == true
                                ? () => renameEntry(context, path)
                                : null,
                            finish:
                                file &&
                                    (confirmable ||
                                        entry['finishPending'] == true)
                                ? TextButton.icon(
                                    key: ValueKey('finish:$path'),
                                    onPressed: confirmable
                                        ? () => finishEditing(context, entry)
                                        : null,
                                    icon: const Icon(Icons.done, size: 18),
                                    label: Text(
                                      confirmable
                                          ? 'Finish editing'
                                          : 'Finish pending',
                                    ),
                                  )
                                : null,
                            menu: entry['synthetic'] == true
                                ? null
                                : PopupMenuButton<String>(
                                    tooltip: directory
                                        ? 'Folder actions'
                                        : 'File actions',
                                    onSelected: (action) {
                                      switch (action) {
                                        case 'local':
                                        case 'cloud':
                                          controller.command(
                                            'retention',
                                            path,
                                            value: action,
                                          );
                                        case 'delete':
                                          unawaited(delete(context, entry));
                                        case 'share':
                                          unawaited(
                                            showManageSharing(
                                              context,
                                              path: path,
                                              call: controller.sharing,
                                            ),
                                          );
                                        case 'addFiles':
                                        case 'addFolder':
                                          unawaited(
                                            addFromPicker(
                                              context,
                                              widget.addFiles!,
                                              path,
                                              folder: action == 'addFolder',
                                            ),
                                          );
                                        case 'recover':
                                          unawaited(_recover(entry));
                                        case 'dismiss':
                                          unawaited(_dismiss([entry]));
                                        case 'both':
                                          controller.command('keepBoth', path);
                                        case 'details':
                                          showDialog<void>(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              title: Text(path),
                                              scrollable: compactLayout(
                                                context,
                                              ),
                                              content: SelectableText(
                                                'Status: ${entry['status']}\n${entry['conflict'] ?? ''}\nPreserved local copies:\n${(entry['preservedCopies'] as List? ?? []).join('\n')}\nEditor working copies (retained until Finish editing):\n${workingCopyDetails(entry)}\n${artifactSummary(entry) ?? 'Local staging files: ${(entry['localArtifacts'] as Map?) == null ? 'unknown' : 'none'}'}\nLocal temporary/recovery locations:\n${localRecoveryDetails(entry)}\nRemote conflict copy: ${entry['remoteCopy'] ?? 'none'}',
                                              ),
                                              actions: [
                                                if (openedCopies(entry)
                                                    .isNotEmpty)
                                                  TextButton(
                                                    key: ValueKey(
                                                      'removeOpened:$path',
                                                    ),
                                                    onPressed: () {
                                                      Navigator.pop(context);
                                                      unawaited(
                                                        removeOpenedCopy(
                                                          this.context,
                                                          entry,
                                                        ),
                                                      );
                                                    },
                                                    child: const Text(
                                                      'Remove opened copy',
                                                    ),
                                                  ),
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(context),
                                                  child: const Text('Close'),
                                                ),
                                              ],
                                            ),
                                          );
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      if (hasRecoveryCopies(entry)) ...[
                                        PopupMenuItem(
                                          key: ValueKey('recover:$path'),
                                          value: 'recover',
                                          enabled: canRecover(entry),
                                          child: const Text('Recover'),
                                        ),
                                        PopupMenuItem(
                                          key: ValueKey('dismiss:$path'),
                                          value: 'dismiss',
                                          child: const Text('Dismiss'),
                                        ),
                                        const PopupMenuDivider(),
                                      ],
                                      // Documents, Music and Videos always
                                      // stay; their menu holds the choice
                                      // for what is inside (decision #163).
                                      if (directory && isTopFolder(path)) ...[
                                        CheckedPopupMenuItem(
                                          key: ValueKey('contents-local:$path'),
                                          value: 'local',
                                          checked:
                                              entry['contentsRetention'] !=
                                              'cloud',
                                          child: const Text(
                                            'Keep new and loose files on this device',
                                          ),
                                        ),
                                        CheckedPopupMenuItem(
                                          key: ValueKey('contents-cloud:$path'),
                                          value: 'cloud',
                                          checked:
                                              entry['contentsRetention'] ==
                                              'cloud',
                                          child: const Text(
                                            'New and loose files: cloud only',
                                          ),
                                        ),
                                      ] else if (directory) ...[
                                        const PopupMenuItem(
                                          value: 'local',
                                          child: Text('Local and cloud'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'cloud',
                                          child: Text(
                                            'Cloud-only / free up space',
                                          ),
                                        ),
                                      ] else if (file &&
                                          !deletedSelectionStatus(
                                            entry['status'] as String?,
                                          ))
                                        ..._fileStorageMenuItems(path, entry),
                                      // Spec #43: copy from the phone.
                                      if (widget.addFiles != null &&
                                          addOffered(entry))
                                        ...addMenuItems(
                                          path,
                                          addDestinationProblem(
                                            entry,
                                            ready: controller.canCreateFolder,
                                            paused: controller.paused,
                                          ),
                                        ),
                                      if (manageSharingItem(
                                        entry,
                                        null,
                                      ).offered)
                                        _manageSharingMenuItem(
                                          path,
                                          manageSharingItem(
                                            entry,
                                            controller.sharingUnavailable,
                                          ).disabledReason,
                                        ),
                                      // A completed deletion has nothing
                                      // left to delete everywhere.
                                      if (!unsupported &&
                                          !isTopFolder(path) &&
                                          offersDeleteEverywhere(entry) &&
                                          !(dismissOnly(entry) &&
                                              hasRecoveryCopies(entry)))
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete everywhere'),
                                        ),
                                      if (entry['conflict'] != null &&
                                          file &&
                                          entry['canRecoverLocalVariants'] ==
                                              true)
                                        PopupMenuItem(
                                          value: 'both',
                                          child: Text(
                                            entry['expectedPresent'] == true
                                                ? 'Keep both versions'
                                                : 'Recover local edits as new files',
                                          ),
                                        ),
                                      const PopupMenuItem(
                                        value: 'details',
                                        child: Text(
                                          'Details and preserved copies',
                                        ),
                                      ),
                                    ],
                                  ),
                          );
                        },
                      );
                // A phone in landscape (spec #28 Phone Layout): the status,
                // tabs and toolbar scroll away with the list, and the Select
                // actions stay at the bottom.
                if (short) {
                  return Column(
                    children: [
                      Expanded(
                        child: NestedScrollView(
                          headerSliverBuilder: (context, _) => [
                            SliverToBoxAdapter(child: Column(children: top)),
                          ],
                          body: list,
                        ),
                      ),
                      ...selection,
                    ],
                  );
                }
                return Column(
                  children: [
                    // The list always keeps room on a phone (spec #28).
                    if (compact)
                      CappedHeader(
                        available: body.maxHeight,
                        child: Column(children: top),
                      )
                    else
                      ...top,
                    ...selection,
                    Expanded(child: list),
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

/// Below a ranked list: centred, borderless text buttons in the theme's
/// primary colour. More adds a page; Less returns to the first page.
class _RankedPager extends StatelessWidget {
  const _RankedPager({this.onMore, this.onLess});
  final VoidCallback? onMore;
  final VoidCallback? onLess;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (onMore != null)
          TextButton(
            key: const ValueKey('ranked-more'),
            onPressed: onMore,
            child: const Text('More'),
          ),
        if (onMore != null && onLess != null) const SizedBox(width: 8),
        if (onLess != null)
          TextButton(
            key: const ValueKey('ranked-less'),
            onPressed: onLess,
            child: const Text('Less'),
          ),
      ],
    ),
  );
}

/// A file's storage choice in its ⋮ menu (spec #45 R3): the current one
/// checked, "(as folder)" when the file follows its folder.
List<PopupMenuEntry<String>> _fileStorageMenuItems(
  String path,
  Map<String, dynamic> entry,
) {
  final cloud = entry['effectiveRetention'] == 'cloud';
  final inherited = entry['override'] == null;
  return [
    for (final (value, label) in const [
      ('cloud', 'Cloud-only / free up space'),
      ('local', 'Keep on this device'),
    ])
      CheckedPopupMenuItem<String>(
        key: ValueKey('file-$value:$path'),
        value: value,
        checked: cloud == (value == 'cloud'),
        child: Text(
          cloud == (value == 'cloud') && inherited
              ? '$label (as folder)'
              : label,
        ),
      ),
  ];
}

/// "Manage sharing…" in a folder's ⋮ menu (spec #26); when disabled, the
/// reason is its tooltip and part of its screen-reader label.
PopupMenuItem<String> _manageSharingMenuItem(String path, String? reason) =>
    PopupMenuItem<String>(
      key: ValueKey('manage-sharing:$path'),
      value: 'share',
      enabled: reason == null,
      child: Tooltip(
        message: reason ?? 'Share this folder with household users',
        child: Text(
          'Manage sharing…',
          semanticsLabel: reason == null
              ? 'Manage sharing…'
              : 'Manage sharing… unavailable: $reason',
        ),
      ),
    );

/// An app-bar action: icon and label on wide windows; on a narrow phone the
/// same icon as an icon button whose tooltip and screen-reader label are the
/// same words (spec #28 Phone Layout: same vocabulary, 48 dp targets).
class _AppBarAction extends StatelessWidget {
  const _AppBarAction({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => compactWidth(context)
      ? IconButton(onPressed: onPressed, tooltip: label, icon: Icon(icon))
      : TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
}
