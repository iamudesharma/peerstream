import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';

/// Explicitly isolate service-only tests from filesystem plugins and user data.
class EmptyPlaybackCache extends PlaybackCacheStore {
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<PlaybackCacheEntry?> lookup(TorrentSource source) async => null;
  @override
  Future<PlaybackCacheEntry?> lookupRequest(
    MediaRef media,
    int? season,
    int? episode,
    String sourceId,
  ) async => null;
  @override
  Future<List<PlaybackCacheEntry>> entries() async => [];
  @override
  Future<PlaybackPreferences> preferences() async =>
      const PlaybackPreferences(maxCacheBytes: 512 * 1024 * 1024);
  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) async {}
  @override
  Future<void> recordTimeByteObservation(
    TorrentSource source,
    int positionMs,
    int byteOffset, {
    required int fileSize,
  }) async {}
  @override
  Future<void> pruneIfNeeded({String? protectedKey}) async {}
}
