import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';

/// Saved position for this exact title and episode, or null when none.
int? resumeMsForSource({
  required TorrentSource source,
  required List<WatchEntry>? history,
}) {
  final entries = history;
  if (entries == null || entries.isEmpty) return null;
  final key = watchKey(
    source.content,
    source.seasonNumber,
    source.episodeNumber,
  );
  for (final entry in entries) {
    if (entry.key == key) {
      return entry.positionMs > 0 ? entry.positionMs : null;
    }
  }
  return null;
}
