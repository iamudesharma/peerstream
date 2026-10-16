import '../../models/torrent_models.dart';
import '../../models/media_item.dart';
import '../../models/watch_progress.dart';
import '../playback/playback_cache.dart';
import '../playback/playback_cache_models.dart';
import '../playback/torrent_cache_identity.dart';
import 'service_client.dart';

/// Prototype cache: the service is the sole writer, including its existing-format index.
class ServicePlaybackCacheStore extends PlaybackCacheStore {
  ServicePlaybackCacheStore(this.client);
  final LocalServiceClient client;
  Future<Map> _index() async {
    // Idempotent reads may start a new owner after confirmed helper death.
    // Session mutations still require engine initialization and fresh handles.
    await client.start(restart: true);
    return await client.command('cacheIndex') as Map;
  }

  @override
  Future<List<PlaybackCacheEntry>> entries() async =>
      ((await _index())['entries'] as List)
          .whereType<Map>()
          .map((r) => PlaybackCacheEntry.fromJson(Map<String, dynamic>.from(r)))
          .toList();
  @override
  Future<PlaybackCacheEntry?> lookup(TorrentSource source) async =>
      (await entries())
          .where((e) => e.cacheKey == torrentCacheKey(source))
          .firstOrNull;
  @override
  Future<PlaybackCacheEntry?> lookupWatch(WatchEntry entry) async =>
      (await entries()).where((e) => e.matchesWatchEntry(entry)).firstOrNull;
  @override
  Future<PlaybackCacheEntry?> lookupRequest(
    MediaRef media,
    int? season,
    int? episode,
    String sourceId,
  ) async => (await entries())
      .where(
        (e) =>
            e.source.id == sourceId &&
            e.source.content == media &&
            e.source.seasonNumber == season &&
            e.source.episodeNumber == episode,
      )
      .firstOrNull;
  // Until signed helper access is accepted, cached playback is reverified through the service.
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<bool> hasCompleteFile(TorrentSource source) async => false;
  @override
  Future<String> directoryPathFor(TorrentSource source) async =>
      '${client.root}/payload/${torrentCacheKey(source)}';
  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) async {
    final entry = PlaybackCacheEntry(
      cacheKey: torrentCacheKey(source),
      source: source,
      file: file,
      filePath: '',
      complete: false,
      byteSize: byteSize,
      lastUsedAt: DateTime.now(),
    );
    await client.command('cacheRecord', entry.toJson());
  }

  @override
  Future<void> recordTimeByteObservation(
    TorrentSource source,
    int positionMs,
    int byteOffset, {
    required int fileSize,
  }) async {
    final entry = await lookup(source);
    if (entry == null) return;
    final points = mergeTimeBytePoint(
      entry.timeBytePoints,
      TimeBytePoint(positionMs: positionMs, byteOffset: byteOffset),
      fileSize: fileSize,
    );
    await client.command('cacheObserve', {
      'cacheKey': entry.cacheKey,
      'points': points.map((p) => p.toJson()).toList(),
    });
  }

  @override
  Future<void> pruneIfNeeded({String? protectedKey}) async {
    await client.command('cachePrune', {'protectedKey': protectedKey});
  }

  @override
  Future<PlaybackCacheSummary> summary() async {
    final rows = await entries();
    final prefs = await preferences();
    return PlaybackCacheSummary(
      byteSize:
          ((await client.command('cacheUsage') as Map)['allocatedBytes'] as num)
              .toInt(),
      maxBytes: prefs.maxCacheBytes,
      entries: rows.length,
    );
  }

  @override
  Future<PlaybackPreferences> preferences() async {
    final index = await _index();
    return PlaybackPreferences(
      maxCacheBytes: (index['maxCacheBytes'] as num).toInt(),
      preferredAudioLanguage: index['preferredAudioLanguage'] as String?,
      preferredSubtitleLanguage: index['preferredSubtitleLanguage'] as String?,
    );
  }

  @override
  Future<void> savePreferences(PlaybackPreferences value) async {
    await client.command('cachePreferences', {
      'maxCacheBytes': value.maxCacheBytes,
      'preferredAudioLanguage': value.preferredAudioLanguage,
      'preferredSubtitleLanguage': value.preferredSubtitleLanguage,
    });
  }

  @override
  Future<void> setPinned(String cacheKey, bool pinned) async {
    await client.command('cachePin', {'cacheKey': cacheKey, 'pinned': pinned});
  }

  @override
  Future<void> remove(String cacheKey) async {
    await client.command('cacheRemove', {'cacheKey': cacheKey});
  }

  @override
  Future<void> clear() async {
    await client.command('cacheClear');
  }
}
