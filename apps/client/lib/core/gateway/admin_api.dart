import '../state/model.dart';
import 'sharing.dart';

/// Household administration (spec #27, decision #87). Shared Dart: the
/// gateway admin API's transport, the server-issued confirmation flow and
/// the response types. No business rule lives here; the gateway decides.

/// How long one admin HTTP request may wait for the gateway's answer. The
/// gateway answers every admin request within its hold (25 s,
/// `OPERATION_HOLD` in services/access/console.py): an action still running
/// then answers 202 with an operation id, which [AdminClient] polls. So no
/// request stays silent near production HAProxy's 120 s idle limit, which
/// cannot see the path (TLS passthrough; SC-041 F1), and the worker is never
/// held by one admin call for longer than this (SC-041 F2).
const adminRequestTimeout = Duration(seconds: 60);

/// The app's wait for the worker's answer to one admin request: past
/// [adminRequestTimeout], so the worker's own timeout message arrives first.
const adminReplyTimeout = Duration(seconds: 75);

/// How long one admin action may take in all, across its polls. Approve,
/// user add and the other console-backend actions can take up to the
/// gateway's backend timeout (300 s, `BACKEND_TIMEOUT` in
/// services/access/console.py); waiting longer means a slow action that still
/// succeeds is reported with its real result, not as "no response".
const adminActionDeadline = Duration(seconds: 345);

/// The gateway's answer while a long action is still running (HTTP 202).
final _operationId = RegExp(r'^[0-9a-f]{32}$');

/// One admin response: HTTP status and decoded JSON body.
class AdminResponse {
  const AdminResponse(this.status, this.data);
  final int status;
  final Object? data;

  Map<String, dynamic> get map =>
      data is Map ? Map<String, dynamic>.from(data as Map) : const {};
}

/// Sends one request to `/v1/account` or `/v1/admin/...` with this device's
/// certificate. Implemented by the gateway client; forwarded by wrappers.
abstract interface class AdminTransport {
  Future<AdminResponse> admin(
    String method,
    String path, {
    Map<String, Object?>? body,
  });
}

/// Admin calls pass through the worker's cloud wrappers unchanged. They are
/// not file sync, so the pause gate (#53) does not apply to them.
mixin ForwardAdmin on ForwardSharing implements AdminTransport {
  @override
  Future<AdminResponse> admin(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) {
    final target = sharingTarget;
    if (target is AdminTransport) {
      return (target as AdminTransport).admin(method, path, body: body);
    }
    throw const CloudFailure('Admin is not available on this connection.');
  }
}

/// The UI's one way to the admin API; in the app, the controller's call
/// through the worker isolate. Widget tests pass a fake.
typedef AdminCall = Future<AdminResponse> Function(
  String method,
  String path, {
  Map<String, Object?>? body,
});

/// Only these paths are ever requested.
bool adminPathAllowed(String path) =>
    path == '/v1/account' ||
    RegExp(
      r'^/v1/admin/[a-z0-9-]+(/[A-Za-z0-9-]+(/[a-z-]+)?)?(\?[a-z0-9=&]*)?$',
    ).hasMatch(path);

/// A refusal with the gateway's reason class and plain-language message.
class AdminFailure implements Exception {
  const AdminFailure(this.status, this.reason, this.message, {this.revision});
  final int status;
  final String reason;
  final String message;
  final String? revision;

  bool get notAdmin => reason == 'not-admin';
  bool get stale => reason == 'stale';

  @override
  String toString() => message;
}

/// A destructive action's server text (HTTP 428). [typed] is set when the
/// admin must type that account id to confirm.
class ConfirmationPrompt {
  const ConfirmationPrompt(this.title, this.effect, this.token, this.typed);
  final String title;
  final String effect;
  final String token;
  final String? typed;
}

/// Shows a confirmation and returns the typed text ('' when none is asked),
/// or null when the admin cancels; on cancel nothing is sent.
typedef Confirm = Future<String?> Function(ConfirmationPrompt prompt);

class AdminClient {
  AdminClient(this.call, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final AdminCall call;
  final DateTime Function() _now;

  Future<Map<String, dynamic>> get(String path) async =>
      _ok(await _send('GET', path));

  /// One request, then the polls of its operation while the gateway answers
  /// 202 (each poll waits up to the gateway's hold), until the action's own
  /// response or [adminActionDeadline].
  Future<AdminResponse> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final deadline = _now().add(adminActionDeadline);
    var response = await call(method, path, body: body);
    while (response.status == 202) {
      final operation = response.map['operation'];
      if (operation is! String || !_operationId.hasMatch(operation)) break;
      if (_now().isAfter(deadline)) {
        throw const AdminFailure(
          504,
          'no-answer',
          'The server is still working on this. Refresh in a few minutes to '
              'see whether it happened.',
        );
      }
      response = await call('GET', '/v1/admin/operations/$operation');
    }
    return response;
  }

  /// A mutation with the gateway's confirmation flow: a 428 is shown through
  /// [confirm]; Confirm resends with the token, Cancel sends nothing and
  /// returns null.
  Future<Map<String, dynamic>?> mutate(
    String method,
    String path,
    Map<String, Object?> body, {
    required Confirm confirm,
  }) async {
    final first = await _send(method, path, body: body);
    if (first.status != 428) return _ok(first);
    final data = first.map;
    final prompt = ConfirmationPrompt(
      data['title'] as String? ?? 'Confirm',
      data['effect'] as String? ?? '',
      data['confirm_token'] as String? ?? '',
      data['second_factor_typed'] as String?,
    );
    final typed = await confirm(prompt);
    if (typed == null) return null;
    return _ok(
      await _send(
        method,
        path,
        body: {
          ...body,
          'confirm': prompt.token,
          if (prompt.typed != null) 'typed': typed,
        },
      ),
    );
  }

  Map<String, dynamic> _ok(AdminResponse response) {
    if (response.status >= 200 && response.status < 300) return response.map;
    final data = response.map;
    throw AdminFailure(
      response.status,
      data['error'] as String? ?? 'error',
      data['message'] as String? ?? _fallback(response.status),
      revision: data['revision'] as String?,
    );
  }

  static String _fallback(int status) => switch (status) {
    401 => 'This device is not paired.',
    403 => 'Your admin role was removed.',
    503 => "The server's admin service is restarting; try again in a minute.",
    _ => 'The server refused this action ($status).',
  };
}

/// Fingerprint as typed from the new device: spaces, colons and dashes are
/// ignored and case is folded; the result must be 64 hex characters. Never
/// pre-filled.
String? normalizeFingerprint(String typed) {
  final compact = typed.replaceAll(RegExp(r'[\s:-]'), '').toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(compact) ? compact : null;
}
