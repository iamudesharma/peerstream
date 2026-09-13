import '../../models/torrent_models.dart';

abstract interface class TorrentEngine {
  bool get isSupported;
  String? get unsupportedReason;
  Future<void> initialize();
  Future<TorrentHandle> add(TorrentSource source);
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle);
  Stream<TorrentStats> watch(TorrentHandle handle);
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  );

  /// Stops a playback session. Cached bytes are retained unless the caller
  /// explicitly asks to delete them.
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false});
  Future<void> dispose();
}

/// Optional capability: selected-file piece verification.
///
/// Engines that track verified pieces (libtorrent `pieces_have`) implement
/// this to prove a cached file is fully verified — not merely a preallocated
/// sparse file with the right length.
abstract interface class FileCompletenessChecker {
  Future<bool> isFileComplete(TorrentHandle handle, TorrentFileEntry file);
}

/// Optional capability: pre-seek scheduler hints.
///
/// Engines that can reprioritize pieces ahead of the player's first request
/// (libtorrent) implement this so a resume position starts downloading
/// alongside the head/tail metadata instead of waiting for the seek.
abstract interface class StreamPositionController {
  /// Pre-prioritizes pieces around [byteOffset].
  ///
  /// [windowBytes] 0 selects the engine's own heuristic; [urgent] gives the
  /// first pieces the earliest deadlines (rebuffer recovery).
  void setStreamPosition(
    TorrentHandle handle,
    int byteOffset, {
    int windowBytes = 0,
    bool urgent = false,
  });

  /// Reports the observed media duration for bitrate/buffer sizing.
  void setStreamDuration(TorrentHandle handle, int durationMs);

  /// Latest native read head (byte offset) for the active stream, or null.
  int? streamReadHead(TorrentHandle handle);

  /// One-line native scheduler snapshot, or null when unavailable.
  String? streamDebugSnapshot(TorrentHandle handle);
}

/// Optional capability: verified per-file availability snapshot.
///
/// Engines backed by piece-verifying stores (libtorrent) implement this so
/// the app can show true cached/downloaded timeline ranges without moving
/// torrent logic into the player package. The snapshot carries raw
/// byte/piece signals; time mapping stays in PeerStream
/// (`torrentAvailabilityToBufferedRanges`).
abstract interface class TorrentAvailabilityProvider {
  /// Verified availability for [fileIndex] of torrent [torrentId], or `null`
  /// when the engine currently has no data for it.
  TorrentFileAvailability? fileAvailability(int torrentId, int fileIndex);
}

/// Optional capability: runtime native build identity and cache telemetry.
abstract interface class EngineDiagnosticsProvider {
  /// Version string identifying the exact native bridge revision
  /// (e.g. `bridge-1.4.2+lt2.0.11`). Used to confirm all platforms ship
  /// the same implementation before comparing performance.
  String get bridgeVersion;

  Future<EngineDiagnostics> engineDiagnostics();
}

class EngineDiagnostics {
  const EngineDiagnostics({
    required this.bridgeVersion,
    this.cacheCapacityBytes,
    this.cacheFilledBytes,
    this.activeStreams = 0,
  });

  final String bridgeVersion;
  final int? cacheCapacityBytes;
  final int? cacheFilledBytes;
  final int activeStreams;
}

TorrentFileEntry selectVideoFile(List<TorrentFileEntry> files, {String? hint}) {
  final videos = files.where((file) {
    final lower = file.name.toLowerCase();
    const extensions = ['.mp4', '.m4v', '.mkv', '.webm', '.avi', '.mov'];
    return file.isStreamable &&
        extensions.any(lower.endsWith) &&
        !lower.contains('sample') &&
        !lower.contains('trailer');
  }).toList();
  if (videos.isEmpty) throw StateError('This torrent has no streamable video.');
  final normalizedHint = hint?.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  if (normalizedHint != null && normalizedHint.isNotEmpty) {
    final matches = videos.where((file) {
      final normalizedName = file.name.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      return normalizedName.contains(normalizedHint);
    }).toList();
    if (matches.isNotEmpty) {
      matches.sort((a, b) => b.size.compareTo(a.size));
      return matches.first;
    }
  }
  videos.sort((a, b) => b.size.compareTo(a.size));
  return videos.first;
}

/// Byte offset of a resume position inside a media file, used to hint the
/// torrent scheduler before the player seeks. Pure so the mapping stays
/// testable without a native engine.
int resumeByteOffset({
  required int positionMs,
  required int durationMs,
  required int fileSize,
}) {
  if (positionMs <= 0 || durationMs <= 0 || fileSize <= 0) return 0;
  final offset = (positionMs / durationMs) * fileSize;
  return offset.round().clamp(0, fileSize);
}

/// Forward prefetch budget in bytes for a resume/seek hint.
///
/// Sized in seconds of video rather than a fixed MB window: a fast swarm gets
/// a smaller buffer, a slow or unstable one a larger one. [bitrateBps] should
/// come from the learned time↔byte map when available, else the file-average
/// bitrate. Pure so the policy stays testable.
int adaptiveWindowBytes({
  required int bitrateBps,
  required int bufferedAheadMs,
  required int downloadRateBps,
  required int peers,
}) {
  if (bitrateBps <= 0) return 0;
  final bufferedSeconds = bufferedAheadMs / 1000.0;
  double seconds;
  if (bufferedSeconds >= 60) {
    seconds = 15;
  } else if (bufferedSeconds >= 30) {
    seconds = 25;
  } else if (bufferedSeconds >= 10) {
    seconds = 40;
  } else {
    // Startup, resume, or actively starving: fetch aggressively.
    seconds = 60;
  }
  if (downloadRateBps > 0) {
    if (downloadRateBps > bitrateBps * 2) {
      // Swarm comfortably outruns the media: don't over-buffer.
      seconds *= 0.6;
    } else if (downloadRateBps < bitrateBps * 1.2) {
      // Swarm is the bottleneck: build a deeper safety margin.
      seconds *= 1.5;
    }
  }
  if (peers > 0 && peers < 4) seconds *= 1.3; // thin/unstable swarm
  seconds = seconds.clamp(10, 90);
  return (bitrateBps * seconds).round();
}
