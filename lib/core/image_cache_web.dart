import 'package:flutter_cache_manager/flutter_cache_manager.dart';

BaseCacheManager get artworkCacheManager => DefaultCacheManager();
Future<void> clearArtworkCache() => artworkCacheManager.emptyCache();
