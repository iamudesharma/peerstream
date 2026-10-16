import 'native_torrent_engine.dart';
import 'torrent_engine.dart';
import '../playback/playback_cache.dart';
import '../local_service/service_backend_native.dart';
import '../local_service/service_torrent_engine.dart';
import '../local_service/service_cache.dart';

TorrentEngine createTorrentEngine() => experimentalService == null
    ? NativeTorrentEngine()
    : ServiceTorrentEngine(experimentalService!);
PlaybackCacheStore createPlaybackCache() => experimentalService == null
    ? PlaybackCacheStore()
    : ServicePlaybackCacheStore(experimentalService!);
