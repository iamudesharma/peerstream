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
  String? nativeBuild;
  int? cacheCapacityBytes;
  int? cacheFilledBytes;

  Duration? get tapToFirstFrame {
    if (sessionClaimedAt == null || firstFrameAt == null) return null;
    return firstFrameAt!.difference(sessionClaimedAt!);
  }

  Map<String, dynamic> toMap() => {
    'sessionId': sessionId,
    'tapToFirstFrameMs': tapToFirstFrame?.inMilliseconds,
    'bufferingEvents': bufferingEvents,
    'stallEvents': stallEvents,
    'seekEvents': seekEvents,
    'nativeBuild': nativeBuild,
    'cacheCapacityBytes': cacheCapacityBytes,
    'cacheFilledBytes': cacheFilledBytes,
  };
}
