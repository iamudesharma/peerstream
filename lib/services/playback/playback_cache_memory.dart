import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  bool _prefsLoaded = false;

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
  Future<void> pruneIfNeeded({String? protectedKey}) async {}
  Future<PlaybackCacheSummary> summary() async => PlaybackCacheSummary(
    byteSize: 0,
    maxBytes: (await preferences()).maxCacheBytes,
    entries: 0,
  );
  Future<PlaybackPreferences> preferences() async {
    if (kIsWeb && !_prefsLoaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final audio = prefs.getString('peerstream-pref-audio');
        final subtitle = prefs.getString('peerstream-pref-subtitle');
        final maxBytes = prefs.getInt('peerstream-pref-max-bytes');
        _preferences = PlaybackPreferences(
          maxCacheBytes: maxBytes ?? _preferences.maxCacheBytes,
          preferredAudioLanguage: audio,
          preferredSubtitleLanguage: subtitle,
        );
      } catch (_) {}
      _prefsLoaded = true;
    }
    return _preferences;
  }

  Future<void> savePreferences(PlaybackPreferences value) async {
    // Preference-only write: no eviction scan. Web persists via
    // SharedPreferences so audio/subtitle choices survive reload.
    _preferences = value;
    if (kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (value.preferredAudioLanguage != null) {
          await prefs.setString(
            'peerstream-pref-audio',
            value.preferredAudioLanguage!,
          );
        }
        if (value.preferredSubtitleLanguage != null) {
          await prefs.setString(
            'peerstream-pref-subtitle',
            value.preferredSubtitleLanguage!,
          );
        }
        await prefs.setInt('peerstream-pref-max-bytes', value.maxCacheBytes);
      } catch (_) {}
    }
  }

  Future<void> remove(String cacheKey) async => _entries.remove(cacheKey);
  Future<void> clear() async => _entries.clear();
}
