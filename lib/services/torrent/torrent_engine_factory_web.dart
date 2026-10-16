import 'torrent_engine.dart';
import '../playback/playback_cache.dart';
import 'web_torrent_engine.dart';

TorrentEngine createTorrentEngine() => WebTorrentEngine();

PlaybackCacheStore createPlaybackCache() => PlaybackCacheStore();
