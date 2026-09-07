/// Status of selected-file verification for cached/offline playback.
///
/// A sparse or partially downloaded file can report a full file length on
/// disk while missing verified pieces for the selected video. Only
/// [verified] qualifies as complete offline playback.
enum FileVerificationStatus {
  unknown,
  verified,
  partial,
  missing,
}

/// Coordinated timeout budget for one playback request.
///
/// Different layers must abandon the same request at the same time. The
/// player's mpv `network-timeout` and the native piece wait previously
/// disagreed (60s vs 300s), leaving the UI stuck after mpv had given up.
class StreamingTimeouts {
  const StreamingTimeouts._();

  /// mpv network timeout applied to every profile.
  static const playerNetworkTimeout = Duration(seconds: 60);

  /// How long the local HTTP server waits for a missing piece before
  /// failing the range request. Matches [playerNetworkTimeout] so the
  /// native layer and the player abandon together.
  static const nativePieceWait = Duration(seconds: 60);

  /// Metadata (file list) wait. Longer than a single piece wait because
  /// it requires tracker/DHT round trips on cold magnets.
  static const metadataWait = Duration(seconds: 90);

  /// Single disk-read round trip inside serve_range.
  static const diskReadWait = Duration(seconds: 10);
}

/// mpv tuning profiles. Direct HTTP, local torrent HTTP, and completed
/// files have different latency/throughput trade-offs and must not share
/// one setting block.
///
/// Note on mpv semantics: `cache-secs` caps the forward cache and can
/// override the smaller `demuxer-readahead-secs`. They are not independent
/// startup controls — keep cache-secs >= readahead.
enum PlayerProfileKind { direct, torrent, cache }

class PlayerProfile {
  const PlayerProfile({
    required this.networkTimeoutSecs,
    required this.demuxerMaxBytes,
    required this.cacheSecs,
    required this.readaheadSecs,
  });

  final String networkTimeoutSecs;
  final String demuxerMaxBytes;
  final String cacheSecs;
  final String readaheadSecs;

  static const direct = PlayerProfile(
    networkTimeoutSecs: '30',
    demuxerMaxBytes: '33554432',
    cacheSecs: '10',
    readaheadSecs: '5',
  );

  static const torrent = PlayerProfile(
    // Local torrent HTTP may legitimately stall waiting for a piece;
    // match StreamingTimeouts.playerNetworkTimeout.
    networkTimeoutSecs: '60',
    demuxerMaxBytes: '33554432',
    cacheSecs: '20',
    readaheadSecs: '10',
  );

  static const cache = PlayerProfile(
    networkTimeoutSecs: '10',
    demuxerMaxBytes: '67108864',
    cacheSecs: '30',
    readaheadSecs: '10',
  );

  static PlayerProfile forOrigin(bool fromCache, bool isDirect) {
    if (fromCache) return cache;
    if (isDirect) return direct;
    return torrent;
  }
}
