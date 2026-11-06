/// Cost of one reconcile pass. Exposed to tests through `SyncEngine.lastPass`
/// and written by the worker when `ANJ_CLIENT_METRICS` names a file.
class PassMetrics {
  const PassMetrics({
    required this.full,
    required this.completed,
    required this.candidates,
    required this.pathsVisited,
    required this.filesHashed,
    required this.bytesHashed,
    required this.filesHashedBy,
    required this.rowsWritten,
    required this.transactions,
    required this.durationMicros,
    this.localScan = 'full',
    this.pathsStatted = 0,
    this.fullScans = 0,
  });

  /// How local changes were found: `full` (stat scan of the whole root) or
  /// `partial` (queued, due and engine-touched paths only, spec #15).
  final String localScan;

  /// Items stat-ed by a partial pass (a full pass reports the whole view).
  final int pathsStatted;

  /// Full stat scans since the engine started.
  final int fullScans;

  /// Whether every path was reconciled (startup or audit).
  final bool full;

  /// Whether the pass reached its end (not offline, paused or stopped).
  final bool completed;
  final int candidates;
  final int pathsVisited;
  final int filesHashed;
  final int bytesHashed;
  final Map<String, int> filesHashedBy;
  final int rowsWritten;
  final int transactions;
  final int durationMicros;
  Map<String, Object> toJson() => {
    'full': full,
    'completed': completed,
    'candidates': candidates,
    'pathsVisited': pathsVisited,
    'filesHashed': filesHashed,
    'bytesHashed': bytesHashed,
    'filesHashedBy': filesHashedBy,
    'rowsWritten': rowsWritten,
    'transactions': transactions,
    'durationMicros': durationMicros,
    'localScan': localScan,
    'pathsStatted': pathsStatted,
    'fullScans': fullScans,
  };
}
