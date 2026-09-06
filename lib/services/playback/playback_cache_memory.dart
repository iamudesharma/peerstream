import '../../models/torrent_models.dart';
import '../../models/media_item.dart';
import '../../models/watch_progress.dart';
import 'playback_cache_models.dart';
import 'torrent_cache_identity.dart';

class PlaybackCacheStore {
  final Map<String, PlaybackCacheEntry> _entries = {};
  PlaybackPreferences _preferences = const PlaybackPreferences(
    maxCacheBytes: 1024 * 1024 * 1024,
  );

  Future<PlaybackCacheEntry?> lookup(TorrentSource source) async =>
      _entries[torrentCacheKey(source)];
  Future<PlaybackCacheEntry?> lookupWatch(WatchEntry entry) async => _entries
      .values
      .where((item) => item.matchesWatchEntry(entry))
      .firstOrNull;
  Future<PlaybackCacheEntry?> lookupRequest(
    MediaRef media,
    int? season,
    int? episode,
    String sourceId,
  ) async => _entries.values
      .where(
        (item) =>
            item.source.id == sourceId &&
            item.source.content == media &&
            item.source.seasonNumber == season &&
            item.source.episodeNumber == episode,
      )
      .firstOrNull;
  Future<bool> hasCompleteFile(TorrentSource source) async => false;
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  Future<String> directoryPathFor(TorrentSource source) async => '';
  Future<List<PlaybackCacheEntry>> entries() async => _entries.values.toList();
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
  }) async {}
  Future<PlaybackCacheSummary> summary() async => PlaybackCacheSummary(
    byteSize: 0,
    maxBytes: _preferences.maxCacheBytes,
    entries: 0,
  );
  Future<PlaybackPreferences> preferences() async => _preferences;
  Future<void> savePreferences(PlaybackPreferences value) async =>
      _preferences = value;
  Future<void> remove(String cacheKey) async => _entries.remove(cacheKey);
  Future<void> clear() async => _entries.clear();
}
