import 'package:media_forge_player/media_forge_player.dart';

import '../../models/torrent_models.dart';

/// Converts verified torrent availability into player-agnostic buffered
/// time ranges for [MediaForgePlayerController.setExternalBufferedRanges].
///
/// Layering: torrent specifics (pieces, read heads, file sizes) live here in
/// PeerStream. MediaForge only ever receives [MediaForgeBufferedRange]
/// values and stays torrent-agnostic; its internal (FFmpeg read-ahead)
/// buffering is untouched — the controller unions both sets for display.
///
/// Honesty rules (never fake sparse pieces as available):
/// * verified-complete file (or verified local cache) → the whole timeline;
/// * otherwise the native scheduler's contiguous verified window ahead of
///   its read head, mapped to time;
/// * anything else (unknown size/duration, no verified window) → empty.
///
/// Byte→time mapping is proportional (`bytes / fileSize * duration`):
/// exact for constant-bitrate content, an approximation otherwise. It is
/// only used to place the genuinely verified window on the timeline, never
/// to invent availability.
List<MediaForgeBufferedRange> torrentAvailabilityToBufferedRanges({
  required TorrentFileAvailability availability,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return const [];
  if (availability.isComplete) {
    return [MediaForgeBufferedRange(start: Duration.zero, end: duration)];
  }
  final fileSize = availability.fileSizeBytes;
  if (fileSize <= 0) return const [];
  final aheadSeconds = availability.bufferedSecondsAhead;
  if (!(aheadSeconds > 0) || !aheadSeconds.isFinite) return const [];
  final readHead = availability.readHeadBytes.clamp(0, fileSize);
  final startMs =
      (readHead / fileSize * duration.inMilliseconds).round().clamp(
        0,
        duration.inMilliseconds,
      );
  final start = Duration(milliseconds: startMs);
  var end =
      start + Duration(microseconds: (aheadSeconds * 1e6).round());
  if (end > duration) end = duration;
  if (end <= start) return const [];
  return normalizeBufferedRanges([
    MediaForgeBufferedRange(start: start, end: end),
  ]);
}
