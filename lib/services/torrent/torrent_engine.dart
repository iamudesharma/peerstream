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
