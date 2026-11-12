import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../gateway/fetch_api.dart';

/// The Downloader's state (spec #42 F4): whether the gateway offers it, the
/// account's job rows, the remembered Audio/Video and resolution choice, and
/// polling while the tab is on screen. The UI (F5) reads and calls this only;
/// every request goes through [transport] (in the app, the sync worker,
/// which holds this device's certificate).
///
/// Polling, as one rule: a list request runs when the tab becomes visible,
/// on [refresh], after every change this client makes, and then every
/// [pollInterval] after the previous answer while the tab stays visible and
/// any row is unfinished. Nothing is requested while the tab or the app is
/// hidden, except [probe] and the user's own actions.
class FetchJobs extends ChangeNotifier {
  FetchJobs(
    this.transport, {
    required this.requestSync,
    FetchPreferences? preferences,
    this.pollInterval = const Duration(seconds: 2),
    this.probeRetry = const Duration(seconds: 30),
    Timer Function(Duration delay, void Function() callback)? timer,
    Duration Function()? clock,
  }) : preferences = preferences ?? FetchPreferences.memory(),
       _timer = timer ?? Timer.new,
       _clock = clock ?? _monotonic();

  final FetchTransport transport;

  /// Asks for one sync pass that lists the cloud (the controller's
  /// `requestSyncPass`), so a finished file appears without waiting for the
  /// schedule.
  final void Function() requestSync;
  final FetchPreferences preferences;
  final Duration pollInterval;

  /// The least time between two availability probes that got no answer.
  final Duration probeRetry;
  final Timer Function(Duration delay, void Function() callback) _timer;
  final Duration Function() _clock;

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Whether this gateway has the Downloader. The tab is shown only when
  /// [FetchAvailability.available].
  FetchAvailability availability = FetchAvailability.unknown;

  /// The account's rows, newest first, as last listed (plus rows this client
  /// just submitted).
  List<FetchJob> get jobs => List.unmodifiable(_jobs);
  List<FetchJob> _jobs = const [];

  /// Whether a list has been received since the start.
  bool loaded = false;

  /// A list request is under way.
  bool get refreshing => _refreshing != null;
  Future<void>? _refreshing;

  /// The last list's failure, cleared by the next good one; the rows shown
  /// are then the previous ones.
  FetchError? listError;

  /// A submit is under way (the Download button waits).
  bool submitting = false;

  bool get hasUnfinished => _jobs.any((job) => !job.isFinished);
  bool get hasFinished => _jobs.any((job) => job.isFinished);

  /// The remembered choice (preferences), used by [submit].
  FetchKind get kind => preferences.kind;
  FetchResolution get resolution => preferences.resolution;

  void setKind(FetchKind value) {
    if (value == preferences.kind) return;
    preferences.save(kind: value);
    notifyListeners();
  }

  void setResolution(FetchResolution value) {
    if (value == preferences.resolution) return;
    preferences.save(resolution: value);
    notifyListeners();
  }

  /// The Downloader tab is the selected tab.
  bool get tabVisible => _tabVisible;
  bool _tabVisible = false;

  /// The app is on screen: window shown (desktop), app in the foreground
  /// (Android). True until told otherwise.
  bool get appVisible => _appVisible;
  bool _appVisible = true;

  /// Polling runs only while both hold.
  bool get visible => _tabVisible && _appVisible;

  void setTabVisible(bool value) => _setVisible(tab: value);
  void setAppVisible(bool value) => _setVisible(app: value);

  void _setVisible({bool? tab, bool? app}) {
    final was = visible;
    _tabVisible = tab ?? _tabVisible;
    _appVisible = app ?? _appVisible;
    if (visible == was) return;
    if (visible) {
      unawaited(refresh());
    } else {
      _cancelPoll();
    }
  }

  Timer? _poll;
  bool _disposed = false;

  /// Ids seen in a state other than done, and ids a sync pass was already
  /// asked for.
  final Map<String, FetchState> _seen = {};
  final Set<String> _synced = {};

  String? _probedFor;
  Duration? _lastProbe;

  /// The once-per-session availability check: one list request (which also
  /// loads the rows). Runs again only when [origin] differs from the probed
  /// one, or when the last probe got no answer and [probeRetry] has passed.
  Future<void> probe(String? origin) async {
    if (origin != _probedFor) {
      _probedFor = origin;
      _lastProbe = null;
      availability = FetchAvailability.unknown;
      _replace(const []);
      loaded = false;
      listError = null;
      _notify();
    }
    if (origin == null || availability != FetchAvailability.unknown) return;
    final last = _lastProbe;
    final now = _clock();
    if (last != null && now - last < probeRetry) return;
    _lastProbe = now;
    await refresh();
  }

  /// Lists the rows now (pull or Refresh). Asked while a list is under way,
  /// one more list follows it (that one may predate a change just made);
  /// the returned future completes after both.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    final running = _refreshing;
    if (running != null) {
      _again = true;
      return running;
    }
    _cancelPoll();
    final future = _refreshing = _lists();
    _notify();
    return future;
  }

  bool _again = false;

  Future<void> _lists() async {
    try {
      do {
        _again = false;
        await _list();
      } while (_again && !_disposed);
    } finally {
      _refreshing = null;
      _schedule();
      _notify();
    }
  }

  Future<void> _list() async {
    try {
      final rows = await transport.listFetchJobs();
      if (_disposed) return;
      listError = null;
      if (rows == null) {
        availability = FetchAvailability.absent;
        _replace(const []);
        return;
      }
      availability = FetchAvailability.available;
      loaded = true;
      _replace(rows);
    } on FetchFailure catch (failure) {
      if (failure.error == FetchError.absent) {
        availability = FetchAvailability.absent;
      }
      listError = failure.error;
    }
  }

  /// Submits [links] (from [parseFetchLinks]) with the remembered [kind]
  /// and [resolution]. Returns null on success (the new rows are shown at
  /// once), or the error to show under the field.
  Future<FetchError?> submit(List<String> links) async {
    if (links.isEmpty) return FetchError.badLink;
    if (submitting) return null;
    submitting = true;
    _notify();
    try {
      final rows = await transport.submitFetchJobs(
        links,
        kind,
        resolution: kind == FetchKind.video ? resolution : null,
      );
      final ids = {for (final row in rows) row.id};
      _replace([...rows, ..._jobs.where((job) => !ids.contains(job.id))]);
      _schedule();
      return null;
    } on FetchFailure catch (failure) {
      if (failure.error == FetchError.absent) {
        availability = FetchAvailability.absent;
      }
      return failure.error;
    } finally {
      submitting = false;
      _notify();
    }
  }

  /// Cancels an unfinished job (Cancel).
  Future<FetchError?> cancel(String id) => _delete(id, removeRow: false);

  /// Removes a finished row (Remove).
  Future<FetchError?> remove(String id) => _delete(id, removeRow: true);

  Future<FetchError?> _delete(String id, {required bool removeRow}) async {
    try {
      await transport.deleteFetchJob(id);
      if (removeRow) _replace(_jobs.where((job) => job.id != id).toList());
      return null;
    } on FetchFailure catch (failure) {
      if (failure.error == FetchError.notFound) {
        // Already gone on the server: the list catches up below.
        _replace(_jobs.where((job) => job.id != id).toList());
        return null;
      }
      return failure.error;
    } finally {
      _notify();
      unawaited(refresh());
    }
  }

  /// Removes every finished row (Clear finished).
  Future<FetchError?> clearFinished() async {
    try {
      await transport.clearFetchJobs();
      _replace(_jobs.where((job) => !job.isFinished).toList());
      return null;
    } on FetchFailure catch (failure) {
      return failure.error;
    } finally {
      _notify();
      unawaited(refresh());
    }
  }

  /// Replaces the rows; a row seen unfinished and now done asks for one
  /// sync pass (once per row, however many polls see it done).
  void _replace(List<FetchJob> rows) {
    var arrived = false;
    for (final row in rows) {
      final before = _seen[row.id];
      if (row.state == FetchState.done &&
          before != null &&
          before != FetchState.done &&
          _synced.add(row.id)) {
        arrived = true;
      }
      _seen[row.id] = row.state;
    }
    _jobs = rows;
    if (arrived && !_disposed) requestSync();
  }

  /// The next poll, when the tab is visible and a row is unfinished.
  void _schedule() {
    _cancelPoll();
    if (_disposed || !visible || _refreshing != null) return;
    if (availability != FetchAvailability.available || !hasUnfinished) return;
    _poll = _timer(pollInterval, () {
      _poll = null;
      if (visible) unawaited(refresh());
    });
  }

  void _cancelPoll() {
    _poll?.cancel();
    _poll = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelPoll();
    super.dispose();
  }
}

enum FetchAvailability {
  /// Not asked yet, or the last probe got no answer (offline, unpaired).
  unknown,

  /// The gateway answered the job list: show the tab.
  available,

  /// The gateway answered 404: no tab.
  absent,
}

/// The Downloader's remembered choice, a presentation preference kept beside
/// the profile like the icon colours (`<profile>/downloader.json`), written
/// whole and atomically. An unreadable file means the defaults (Audio,
/// 1080p); it is replaced at the next choice.
class FetchPreferences {
  FetchPreferences(Directory profile)
    : _file = File('${profile.path}/downloader.json') {
    _load();
  }

  /// Kept in memory only (tests, and a controller without a profile file).
  FetchPreferences.memory() : _file = null;

  final File? _file;
  FetchKind kind = FetchKind.audio;
  FetchResolution resolution = FetchResolution.p1080;

  void _load() {
    final file = _file;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final value = jsonDecode(file.readAsStringSync());
      if (value is! Map) return;
      kind = FetchKind.parse(value['kind']) ?? kind;
      resolution = FetchResolution.parse(value['height']) ?? resolution;
    } on FormatException {
      // Defaults; the next choice rewrites the file.
    } on FileSystemException {
      // Defaults; the choice still works for this run.
    }
  }

  void save({FetchKind? kind, FetchResolution? resolution}) {
    this.kind = kind ?? this.kind;
    this.resolution = resolution ?? this.resolution;
    final file = _file;
    if (file == null) return;
    try {
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(
        jsonEncode({'kind': this.kind.name, 'height': this.resolution.height}),
        flush: true,
      );
      temporary.renameSync(file.path);
    } on FileSystemException {
      // The choice holds for this run; it is not remembered.
    }
  }
}

/// The most links one submit may carry (spec #42 limits).
const fetchLinkLimit = 50;

/// The pasted field, read for submit.
sealed class FetchLinks {
  const FetchLinks();
}

/// The usable links, in order, without duplicates; [ignored] holds the
/// non-blank lines that are not http(s) links (not sent).
final class FetchLinksReady extends FetchLinks {
  const FetchLinksReady(this.links, this.ignored);
  final List<String> links;
  final List<String> ignored;
}

/// More than [fetchLinkLimit] distinct links: nothing is sent.
final class FetchLinksTooMany extends FetchLinks {
  const FetchLinksTooMany(this.count);
  final int count;

  String get message =>
      'Paste at most $fetchLinkLimit links at a time ($count pasted).';
}

/// Splits [text] into lines, trims them, drops blanks and duplicates, and
/// keeps only http and https links with a host.
FetchLinks parseFetchLinks(String text) {
  final links = <String>[];
  final seen = <String>{};
  final ignored = <String>[];
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (!isFetchLink(line)) {
      ignored.add(line);
      continue;
    }
    if (seen.add(line)) links.add(line);
  }
  if (links.length > fetchLinkLimit) return FetchLinksTooMany(links.length);
  return FetchLinksReady(links, ignored);
}

/// One whole line that is an absolute http or https link with a host.
bool isFetchLink(String line) {
  if (line.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(line);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
