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

  Duration? get tapToFirstFrame {
    if (sessionClaimedAt == null || firstFrameAt == null) return null;
    return firstFrameAt!.difference(sessionClaimedAt!);
  }

  Map<String, dynamic> toMap() {
    final activeRebufferMs = _rebufferStartedAt == null
        ? 0
        : DateTime.now().difference(_rebufferStartedAt!).inMilliseconds;
    return {
      'sessionId': sessionId,
      'tapToFirstFrameMs': tapToFirstFrame?.inMilliseconds,
      'bufferingEvents': bufferingEvents,
      'stallEvents': stallEvents,
      'seekEvents': seekEvents,
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
    };
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
