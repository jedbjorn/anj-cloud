import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../state/model.dart';
import 'name_policy.dart';

/// Why one file is not being uploaded right now.
class UploadHold {
  UploadHold(this.signature);

  /// The local file (identity, stamp and content) the hold applies to. Any
  /// change to the file lifts the hold.
  final String signature;

  /// Consecutive interrupted attempts.
  int failures = 0;

  /// Consecutive attempts that failed the same way as the last one.
  int sameKind = 0;
  TransferFailure? lastKind;

  /// No automatic attempt before this time (engine clock).
  Duration notBefore = Duration.zero;

  /// The status the file shows while held: the last error while backing
  /// off, or a size refusal that waits for the file or the user.
  String status = 'queued';

  /// Set for a size refusal: no automatic retry at all.
  bool refused = false;

  /// For a refusal: the limit it was judged against, and whether that was
  /// confirmed by the server (false for the older-gateway best guess).
  int? limit;
  bool confirmed = false;
}

/// Per-file upload retry policy (SC-028).
///
/// A file whose transfer is interrupted (broken pipe, reset, timeout, a
/// server error) waits [base], doubling per consecutive failure up to [max],
/// plus up to 25% jitter, before it is tried again; other files are not
/// affected. A file the server refuses for its size, or that is over the
/// size limit the server reported, is not tried again until it changes or
/// the user retries. Against a gateway that reports no limit and refuses
/// mid-body, [guessAfter] consecutive broken-connection failures of a file
/// over [assumedLimit] are taken as a size refusal ("may be too large").
///
/// Holds live in memory: a restart is a retry. The worker tries a held file
/// again at the first cloud listing after its time has come (listings run at
/// least every 30 s), so no timer is kept here.
class UploadBackoff {
  UploadBackoff({
    this.base = const Duration(seconds: 15),
    this.max = const Duration(minutes: 15),
    this.guessAfter = 3,
    this.assumedLimit = assumedUploadLimit,
    Duration Function()? clock,
    Random? random,
  }) : clock = clock ?? _monotonic(),
       _random = random ?? Random();

  final Duration base;
  final Duration max;
  final int guessAfter;

  /// The limit assumed for a gateway that reports none (test seam).
  final int assumedLimit;
  Duration Function() clock;
  final Random _random;
  final Map<String, UploadHold> _holds = {};

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// The hold on [path] if it still applies to the file as [signature]
  /// describes it now; a changed file, or a refusal the server's current
  /// [limit] no longer supports, is released.
  UploadHold? hold(String path, String signature, {int? size, int? limit}) {
    final hold = _holds[path];
    if (hold == null) return null;
    if (hold.signature != signature ||
        (hold.refused &&
            limit != null &&
            size != null &&
            size <= limit &&
            (hold.limit == null || limit > hold.limit!))) {
      _holds.remove(path);
      return null;
    }
    return hold;
  }

  /// Whether an upload of [path] waits: refused, or not yet due.
  bool waiting(String path, String signature, {int? size, int? limit}) {
    final held = hold(path, signature, size: size, limit: limit);
    return held != null && (held.refused || clock() < held.notBefore);
  }

  /// Status to show for [path] while a hold applies, else null.
  String? status(String path, String signature) =>
      hold(path, signature)?.status;

  /// Holds [path] as too large for the server; returns the status to show.
  String refuse(
    String path,
    String signature, {
    int? limit,
    bool confirmed = true,
  }) {
    final hold = _holds[path] = UploadHold(signature)
      ..refused = true
      ..limit = limit
      ..confirmed = confirmed
      ..status = tooLargeMessage(limit, guess: !confirmed);
    return hold.status;
  }

  /// Records a failed attempt to upload [path] ([size] bytes). Returns the
  /// status to show, or null when [error] is not one this policy handles
  /// (the caller's usual handling applies).
  String? failed(
    String path,
    String signature,
    Object error, {
    required int size,
    int? limit,
  }) {
    if (error is UploadTooLarge) {
      return refuse(path, signature, limit: error.limit ?? limit);
    }
    // The gateway's name backstop (spec #49): the residual row, no hold.
    if (error is NameNotPortable) return error.message;
    final kind = classify(error);
    if (kind == null) return null;
    final previous = _holds[path];
    final hold = previous != null && previous.signature == signature
        ? previous
        : _holds[path] = UploadHold(signature);
    hold.failures++;
    hold.sameKind = hold.lastKind == kind ? hold.sameKind + 1 : 1;
    hold.lastKind = kind;
    if (kind == TransferFailure.write &&
        hold.sameKind >= guessAfter &&
        size > (limit ?? assumedLimit)) {
      return refuse(
        path,
        signature,
        limit: limit ?? assumedLimit,
        confirmed: false,
      );
    }
    var delay = base * (1 << min(hold.failures - 1, 20));
    if (delay > max) delay = max;
    // Up to 25% later, never earlier, so many clients do not retry in step.
    delay += delay * (_random.nextDouble() * 0.25);
    if (delay > max) delay = max;
    hold.notBefore = clock() + delay;
    hold.status = 'pending: $error';
    return hold.status;
  }

  /// The upload of [path] succeeded.
  void succeeded(String path) => _holds.remove(path);

  /// [path] no longer needs uploading (removed before it was synchronized).
  void forget(String path) => _holds.remove(path);

  /// The user asked to retry: every held file may be tried at once.
  void retryAll() => _holds.clear();

  /// Number of held files (test seam).
  int get length => _holds.length;

  /// Transfer interruptions get backoff; anything else (a refused version,
  /// denied access, a paused gate) keeps its existing handling.
  static TransferFailure? classify(Object error) => switch (error) {
    TransferInterrupted(:final kind) => kind,
    FileSystemException() => null,
    IOException() => TransferFailure.write,
    TimeoutException() => TransferFailure.timeout,
    _ => null,
  };
}
