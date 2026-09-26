import '../../models/torrent_models.dart';

/// Immediate, cancellable ownership of a playback session.
///
/// The player must own its session identifier synchronously — before the
/// first `await` — so leaving during metadata resolution can still cancel
/// cleanup. The token is cheap: it only carries the generation id and the
/// source it was claimed for.
class PlaybackSessionToken {
  PlaybackSessionToken(this.id, this.source, this.claimedAt);

  final int id;
  final TorrentSource source;
  final DateTime claimedAt;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;

  @override
  String toString() => 'PlaybackSessionToken(id=$id, cancelled=$_cancelled)';
}

/// Startup stage timestamps for playback diagnostics.
///
/// Record tap-to-first-frame contributors separately so cold/warm cache and
/// per-platform comparisons are meaningful.
class PlaybackDiagnostics {
  PlaybackDiagnostics({required this.sessionId});

  final int sessionId;
  DateTime? sessionClaimedAt;
  DateTime? engineAddAt;
  DateTime? torrentAddedAt;
  DateTime? metadataAt;
  DateTime? streamCreatedAt;
  DateTime? firstFrameAt;
  DateTime? lastBufferingAt;
  DateTime? lastSeekAt;
  int bufferingEvents = 0;
  int stallEvents = 0;
  int seekEvents = 0;
  DateTime? _lastSeekStartedAt;
  int? lastSeekLatencyMs;
  String? nativeBuild;
  int? cacheCapacityBytes;
  int? cacheFilledBytes;
  int? firstHttpRangeAtMs;
  int? firstVerifiedPieceAtMs;
  int? metadataWaitMs;
  int? peerDiscoveryWaitMs;
  int? firstFramePresentedAtMs;
  double bufferedAheadSeconds = 0;
  double targetBufferSeconds = 0;
  int cachedVerifiedBytes = 0;
  int newlyDownloadedBytes = 0;
  int localRereadBytes = 0;
  int activePieceDeadlines = 0;
  int rebufferDurationMs = 0;
  DateTime? _rebufferStartedAt;

  /// First time any peer connected (torrent-level, from stats polling).
  DateTime? firstPeerAt;

  /// First HTTP Range request the localhost server observed (native timing,
  /// epoch ms converted on import).
  DateTime? firstRangeRequestAt;

  /// First required piece requested from the swarm for the active Range.
  DateTime? firstPieceRequestedAt;

  /// First required piece hash-verified and available to serve.
  DateTime? firstPieceCompletedAt;

  /// First payload byte written to the HTTP client.
  DateTime? firstByteSentAt;

  /// Player `open()` call time (media_kit), where observable.
  DateTime? playerOpenAt;

  /// Latest seek-request latency in ms (Range change → target piece
  /// available), when the native layer reports it.
  int? lastSeekResponseMs;

  /// Rebuffer episodes detected after first frame (buffering edges while
  /// playing).
  int rebufferEvents = 0;

  Duration? get tapToFirstFrame {
    if (sessionClaimedAt == null || firstFrameAt == null) return null;
    return firstFrameAt!.difference(sessionClaimedAt!);
  }

  /// Torrent added → metadata (file list) available.
  Duration? get torrentStartupLatency {
    if (torrentAddedAt == null || metadataAt == null) return null;
    return metadataAt!.difference(torrentAddedAt!);
  }

  /// Tap → first HTTP payload byte.
  Duration? get timeToFirstHttpByte {
    if (sessionClaimedAt == null || firstByteSentAt == null) return null;
    return firstByteSentAt!.difference(sessionClaimedAt!);
  }

  /// Player Range request → required piece verified.
  ///
  /// A resumed/cached stream may have verified the piece before the first
  /// Range arrived; that is an instant cache hit, reported as zero rather
  /// than a negative duration.
  Duration? get rangeToPieceLatency {
    if (firstRangeRequestAt == null || firstPieceCompletedAt == null) {
      return null;
    }
    final latency = firstPieceCompletedAt!.difference(firstRangeRequestAt!);
    if (latency.isNegative) return Duration.zero;
    return latency;
  }

  Map<String, dynamic> toMap() {
    final activeRebufferMs = _rebufferStartedAt == null
        ? 0
        : DateTime.now().difference(_rebufferStartedAt!).inMilliseconds;
    return {
      'sessionId': sessionId,
      'tapToFirstFrameMs': tapToFirstFrame?.inMilliseconds,
      'torrentStartupLatencyMs': torrentStartupLatency?.inMilliseconds,
      'timeToFirstHttpByteMs': timeToFirstHttpByte?.inMilliseconds,
      'rangeToPieceLatencyMs': rangeToPieceLatency?.inMilliseconds,
      'bufferingEvents': bufferingEvents,
      'stallEvents': stallEvents,
      'seekEvents': seekEvents,
      'rebufferEvents': rebufferEvents,
      'nativeBuild': nativeBuild,
      'cacheCapacityBytes': cacheCapacityBytes,
      'cacheFilledBytes': cacheFilledBytes,
      'metadataWaitMs': metadataWaitMs,
      'peerDiscoveryWaitMs': peerDiscoveryWaitMs,
      'firstHttpRangeAtMs': firstHttpRangeAtMs,
      'firstVerifiedPieceAtMs': firstVerifiedPieceAtMs,
      'firstFramePresentedAtMs': firstFramePresentedAtMs,
      'bufferedAheadSeconds': bufferedAheadSeconds,
      'targetBufferSeconds': targetBufferSeconds,
      'cachedVerifiedBytes': cachedVerifiedBytes,
      'newlyDownloadedBytes': newlyDownloadedBytes,
      'localRereadBytes': localRereadBytes,
      'activePieceDeadlines': activePieceDeadlines,
      'rebufferDurationMs': rebufferDurationMs + activeRebufferMs,
      'seekLatencyMs': lastSeekLatencyMs,
      'seekResponseMs': lastSeekResponseMs,
    };
  }

  /// One-line startup summary for log-based benchmarking.
  String startupSummary() {
    String ms(Duration? d) => d == null ? 'n/a' : '${d.inMilliseconds}ms';
    return 'startup tapToFirstFrame=${ms(tapToFirstFrame)} '
        'torrent=${ms(torrentStartupLatency)} '
        'firstByte=${ms(timeToFirstHttpByte)} '
        'rangeToPiece=${ms(rangeToPieceLatency)} '
        'seek=${lastSeekLatencyMs ?? lastSeekResponseMs ?? -1}ms '
        'rebuffers=$rebufferEvents';
  }

  void rebufferStarted(DateTime at) => _rebufferStartedAt ??= at;

  void rebufferEnded(DateTime at) {
    final started = _rebufferStartedAt;
    if (started != null) {
      rebufferDurationMs += at.difference(started).inMilliseconds;
    }
    _rebufferStartedAt = null;
  }

  void seekStarted(DateTime at) => _lastSeekStartedAt = at;

  void seekSettled(DateTime at) {
    final started = _lastSeekStartedAt;
    if (started != null) {
      lastSeekLatencyMs = at.difference(started).inMilliseconds;
    }
    _lastSeekStartedAt = null;
  }
}
