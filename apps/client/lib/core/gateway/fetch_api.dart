import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Media fetch (spec #42 F2, F4). Shared Dart: the gateway's job routes over
/// this device's certificate, the job row, and the plain-language outcomes the
/// Downloader shows. The server downloads and places the file; the client
/// only reads and changes job rows.
///
///     POST   /v1/fetch/jobs          {urls, kind, height}  202 with the new rows
///     GET    /v1/fetch/jobs          the account's rows, newest first
///     DELETE /v1/fetch/jobs/{id}     cancel an unfinished job, remove a finished row
///     POST   /v1/fetch/jobs/clear    remove the account's finished rows
///
/// A gateway without the fetch worker answers 404 on all four: the feature is
/// absent. Not file sync: the pause gate does not apply (as for Admin and the
/// update feed), so a paused device can still queue downloads; their files
/// arrive once sync resumes.

/// What a job produces (decision #179): Audio (`.m4a` in Music) or Video
/// (`.mp4` in Videos).
enum FetchKind {
  audio('Audio', 'Music'),
  video('Video', 'Videos');

  const FetchKind(this.label, this.folder);
  final String label;

  /// The top folder results land in ("Saves to Music").
  final String folder;

  static FetchKind? parse(Object? value) =>
      value is String ? values.asNameMap()[value] : null;
}

/// The video preset's height limit (decision #179). Audio has none.
enum FetchResolution {
  p1080(1080, '1080p'),
  p720(720, '720p');

  const FetchResolution(this.height, this.label);
  final int height;
  final String label;

  static FetchResolution? parse(Object? value) {
    for (final resolution in values) {
      if (value == resolution.height) return resolution;
    }
    return null;
  }
}

/// A job's state (spec #42 "Jobs and states"). [unknown] stands for any
/// state a newer gateway may add: it is shown generically and never crashes
/// the client.
enum FetchState {
  waiting,
  checking,
  downloading,
  placing,
  done,
  rejected,
  failed,
  cancelled,
  unknown;

  static FetchState parse(Object? value) =>
      (value is String ? values.asNameMap()[value] : null) ?? unknown;

  /// Terminal: nothing more happens to the row.
  bool get terminal => const {done, rejected, failed, cancelled}.contains(this);
}

/// One job row as the gateway reports it. Unknown fields are ignored; a
/// missing optional field is null. Only [id] is required.
class FetchJob {
  const FetchJob({
    required this.id,
    required this.state,
    this.rawState,
    this.kind,
    this.title,
    this.url,
    this.percent,
    this.path,
    this.message,
    this.height,
    this.submitted,
    this.finished,
  });

  final String id;
  final FetchState state;

  /// The state as the gateway spelled it (kept for an [FetchState.unknown]).
  final String? rawState;
  final FetchKind? kind;

  /// The media title once known.
  final String? title;

  /// The submitted link, when the gateway reports it (the tab shows it until
  /// the title is known).
  final String? url;

  /// 0 to 100 while downloading; null when the gateway gives none.
  final double? percent;

  /// Where the file was placed (relative to the account), once placed.
  final String? path;

  /// The gateway's one plain sentence for a terminal row.
  final String? message;

  /// The height obtained for a video, when the gateway reports it.
  final int? height;
  final DateTime? submitted;
  final DateTime? finished;

  /// Finished for the Downloader's purposes: a terminal state, or (for a state
  /// this client does not know) a reported finish time. An unknown state
  /// without one counts as unfinished, so it is polled until it settles.
  bool get isFinished =>
      state.terminal || (state == FetchState.unknown && finished != null);

  /// Parses one row; null when it has no usable id (the row is skipped).
  static FetchJob? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawId = json['id'];
    final id = rawId is String
        ? rawId
        : rawId is int
        ? '$rawId'
        : null;
    if (id == null || !jobIdPattern.hasMatch(id)) return null;
    final percent = json['percent'];
    final height = json['height'];
    final state = json['state'];
    return FetchJob(
      id: id,
      state: FetchState.parse(state),
      rawState: state is String ? state : null,
      kind: FetchKind.parse(json['kind']),
      title: _text(json['title']),
      url: _text(json['url'] ?? json['link']),
      percent: percent is num && percent.isFinite
          ? percent.toDouble().clamp(0, 100).toDouble()
          : null,
      path: _text(json['path'] ?? json['destination']),
      message: _text(json['message']),
      height: height is int && height > 0 ? height : null,
      submitted: _time(json['submitted'] ?? json['submitted_at']),
      finished: _time(json['finished'] ?? json['finished_at']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'state': rawState ?? state.name,
    'kind': ?kind?.name,
    'title': ?title,
    'url': ?url,
    'percent': ?percent,
    'path': ?path,
    'message': ?message,
    'height': ?height,
    'submitted': ?submitted?.toUtc().toIso8601String(),
    'finished': ?finished?.toUtc().toIso8601String(),
  };

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// Unix seconds (as the gateway's added times) or an ISO 8601 string.
  static DateTime? _time(Object? value) {
    if (value is num && value.isFinite && value >= 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        (value * 1000).round(),
        isUtc: true,
      );
    }
    if (value is String) return DateTime.tryParse(value)?.toUtc();
    return null;
  }
}

/// Ids the client sends back in a path: opaque, short, URL-safe.
final jobIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Every outcome the Downloader shows in plain words. No status code or
/// server text ever reaches the user.
enum FetchError {
  /// 400: a malformed request or a link that is not http(s).
  badLink(
    'One or more links could not be used. Each line must be a full web '
    'address starting with http:// or https://.',
  ),

  /// 403: a read-grant device.
  readOnly('This device can only view files, so it cannot start downloads.'),

  /// 429: the account's unfinished-job cap.
  tooMany('Too many downloads are waiting. Let some finish, then try again.'),

  /// 507: the server's data disk is under its free-space floor.
  storageFull('Server storage is almost full. Free up space, then try again.'),

  /// 503: the fetch worker is not running or writes are fenced.
  busy('The server is busy or under maintenance. Try again in a few minutes.'),

  /// The request did not reach the server or got no answer.
  network("Couldn't reach the server. Check the connection and try again."),

  /// 404 on the routes: this gateway has no Downloader.
  absent('This server does not offer downloads.'),

  /// 401: the device certificate was refused.
  deviceRefused(
    'The server refused this device. Check pairing in Device pairing.',
  ),

  /// 404 on one row: it is no longer on the server.
  notFound('That download is no longer on the server.'),

  /// No running sync worker or not paired: nothing can be sent.
  notConnected('Connect to the server to use the Downloader.'),

  /// Anything else (an unexpected status or answer).
  unexpected("Something went wrong on the server. Try again.");

  const FetchError(this.message);

  /// The sentence to show.
  final String message;

  static FetchError parse(Object? value) =>
      (value is String ? values.asNameMap()[value] : null) ?? unexpected;
}

class FetchFailure implements Exception {
  const FetchFailure(this.error);
  final FetchError error;
  @override
  String toString() => error.message;
}

/// The four job routes. Implemented over HTTP by [HttpFetchTransport] (in
/// the worker, which holds this device's certificate) and over the worker
/// boundary by [MessageFetchTransport] (in the app). Every method throws
/// [FetchFailure] only.
abstract interface class FetchTransport {
  /// The account's rows, newest first; null when the gateway has no
  /// Downloader (404).
  Future<List<FetchJob>?> listFetchJobs();

  /// Submits [urls] (already checked by [parseFetchLinks]); returns the new
  /// rows. [resolution] is sent for video only.
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  });

  /// Cancels an unfinished job or removes a finished row.
  Future<void> deleteFetchJob(String id);

  /// Removes every finished row of the account.
  Future<void> clearFetchJobs();
}

/// How long each stage of one fetch request (connect, answer, body) may
/// wait for the gateway.
const fetchRequestTimeout = Duration(seconds: 30);

/// The app's wait for the worker's answer to one fetch request: past the
/// three stages above, so the worker's own outcome arrives first.
const fetchReplyTimeout = Duration(seconds: 100);

/// The largest job list read (500 unfinished plus 7 days of finished rows).
const fetchListLimit = 4 * 1024 * 1024;

/// [FetchTransport] over [client] (the device's mTLS client) to [origin].
class HttpFetchTransport implements FetchTransport {
  HttpFetchTransport(this.client, this.origin);
  final HttpClient client;
  final Uri origin;

  Uri _uri(List<String> segments) =>
      origin.replace(pathSegments: ['v1', 'fetch', 'jobs', ...segments]);

  /// One request; returns the status and decoded JSON body (null when none or
  /// not JSON). Connection trouble is [FetchError.network].
  Future<(int, Object?)> _send(
    String method,
    List<String> segments, {
    Map<String, Object?>? body,
  }) async {
    HttpClientRequest? request;
    try {
      request = await client
          .openUrl(method, _uri(segments))
          .timeout(fetchRequestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(fetchRequestTimeout);
      final data = <int>[];
      await for (final chunk in response.timeout(fetchRequestTimeout)) {
        if (data.length + chunk.length > fetchListLimit) {
          throw const FetchFailure(FetchError.unexpected);
        }
        data.addAll(chunk);
      }
      Object? decoded;
      try {
        decoded = data.isEmpty ? null : jsonDecode(utf8.decode(data));
      } on FormatException {
        decoded = null;
      }
      return (response.statusCode, decoded);
    } on FetchFailure {
      request?.abort();
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw const FetchFailure(FetchError.network);
    } on IOException {
      // Socket, TLS and HTTP protocol failures alike.
      throw const FetchFailure(FetchError.network);
    }
  }

  static Never _refused(int status) => throw FetchFailure(switch (status) {
    400 => FetchError.badLink,
    401 => FetchError.deviceRefused,
    403 => FetchError.readOnly,
    404 => FetchError.absent,
    429 => FetchError.tooMany,
    503 => FetchError.busy,
    507 => FetchError.storageFull,
    _ => FetchError.unexpected,
  });

  static bool _ok(int status) => status >= 200 && status < 300;

  @override
  Future<List<FetchJob>?> listFetchJobs() async {
    final (status, data) = await _send('GET', const []);
    if (status == 404) return null;
    if (status == 403) throw const FetchFailure(FetchError.deviceRefused);
    if (!_ok(status)) _refused(status);
    return parseFetchJobs(data);
  }

  @override
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  }) async {
    final (status, data) = await _send(
      'POST',
      const [],
      body: {
        'urls': urls,
        'kind': kind.name,
        if (kind == FetchKind.video)
          'height': (resolution ?? FetchResolution.p1080).height,
      },
    );
    if (!_ok(status)) _refused(status);
    return parseFetchJobs(data);
  }

  @override
  Future<void> deleteFetchJob(String id) async {
    if (!jobIdPattern.hasMatch(id)) {
      throw const FetchFailure(FetchError.notFound);
    }
    final (status, _) = await _send('DELETE', [id]);
    if (status == 404) throw const FetchFailure(FetchError.notFound);
    if (!_ok(status)) _refused(status);
  }

  @override
  Future<void> clearFetchJobs() async {
    final (status, _) = await _send('POST', const ['clear']);
    if (!_ok(status)) _refused(status);
  }
}

/// The rows of a list or submit answer: a JSON list, or an object holding it
/// under `jobs`. Rows without a usable id are skipped; anything else that
/// is not a list is [FetchError.unexpected].
List<FetchJob> parseFetchJobs(Object? data) {
  final rows = data is Map ? data['jobs'] : data;
  if (rows is! List) throw const FetchFailure(FetchError.unexpected);
  return [for (final row in rows) ?FetchJob.fromJson(row)];
}

/// The worker's half of the app-to-worker boundary: runs one `fetch`
/// command on [transport] and sends a `fetchResult` event. Never throws.
Future<void> answerFetchCommand(
  FetchTransport? transport,
  Map command,
  void Function(Object? event) send,
) async {
  final request = command['request'];
  try {
    if (transport == null) throw const FetchFailure(FetchError.notConnected);
    Object? data;
    switch (command['op']) {
      case 'list':
        final jobs = await transport.listFetchJobs();
        data = jobs == null ? null : [for (final job in jobs) job.toJson()];
      case 'submit':
        final kind = FetchKind.parse(command['kind']);
        final urls = command['urls'];
        if (kind == null || urls is! List) {
          throw const FetchFailure(FetchError.unexpected);
        }
        final jobs = await transport.submitFetchJobs(
          urls.cast<String>(),
          kind,
          resolution: FetchResolution.parse(command['height']),
        );
        data = [for (final job in jobs) job.toJson()];
      case 'delete':
        await transport.deleteFetchJob(command['id'] as String);
      case 'clear':
        await transport.clearFetchJobs();
      default:
        throw const FetchFailure(FetchError.unexpected);
    }
    send({
      'event': 'fetchResult',
      'request': request,
      'ok': true,
      'data': data,
    });
  } catch (error) {
    send({
      'event': 'fetchResult',
      'request': request,
      'ok': false,
      'error': error is FetchFailure
          ? error.error.name
          : FetchError.unexpected.name,
    });
  }
}

/// The app's half: [FetchTransport] over [call], which sends one command to
/// the worker and completes with its `fetchResult` event (or a failure
/// event the app makes itself, e.g. `notConnected`).
class MessageFetchTransport implements FetchTransport {
  MessageFetchTransport(this.call);
  final Future<Map> Function(Map<String, Object?> command) call;

  Future<Object?> _run(Map<String, Object?> command) async {
    final event = await call({'action': 'fetch', ...command});
    if (event['ok'] != true) {
      throw FetchFailure(FetchError.parse(event['error']));
    }
    return event['data'];
  }

  @override
  Future<List<FetchJob>?> listFetchJobs() async {
    final data = await _run({'op': 'list'});
    return data == null ? null : parseFetchJobs(data);
  }

  @override
  Future<List<FetchJob>> submitFetchJobs(
    List<String> urls,
    FetchKind kind, {
    FetchResolution? resolution,
  }) async => parseFetchJobs(
    await _run({
      'op': 'submit',
      'urls': urls,
      'kind': kind.name,
      if (kind == FetchKind.video)
        'height': (resolution ?? FetchResolution.p1080).height,
    }),
  );

  @override
  Future<void> deleteFetchJob(String id) => _run({'op': 'delete', 'id': id});

  @override
  Future<void> clearFetchJobs() => _run({'op': 'clear'});
}
