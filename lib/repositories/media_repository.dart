import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/season.dart';
import '../services/stremio/stremio_catalog_service.dart';
import '../services/tmdb/tmdb_service.dart';

class MediaRepository {
  const MediaRepository(this._tmdb, [this._stremio]);

  final TmdbService _tmdb;
  final StremioCatalogService? _stremio;

  StremioCatalogService? get stremio => _stremio;

  Future<List<MediaItem>> trendingMovies() => _tmdb.trending(MediaType.movie);
  Future<List<MediaItem>> trendingSeries() => _tmdb.trending(MediaType.tv);
  Future<List<MediaItem>> popularMovies() => _tmdb.popular(MediaType.movie);
  Future<List<MediaItem>> discover(
    MediaType type,
    int genreId, {
    int page = 1,
  }) => _tmdb.discover(type, genreId, page: page);

  /// TMDB first, keyless Stremio/Cinemeta fallback when no token is set.
  Future<List<MediaItem>> search(String query) async {
    try {
      return await _tmdb.search(query);
    } on TmdbConfigurationException {
      final stremio = _stremio;
      if (stremio == null) rethrow;
      return stremio.search(query);
    }
  }

  /// TMDB details first; keyless cached/Cinemeta details when unconfigured.
  Future<MediaDetails> details(MediaRef ref) async {
    try {
      return await _tmdb.details(ref);
    } on TmdbConfigurationException {
      final stremio = _stremio;
      if (stremio == null) rethrow;
      return stremio.details(ref);
    }
  }

  Future<List<Episode>> episodes(int seriesId, int season) async {
    try {
      return await _tmdb.episodes(seriesId, season);
    } on TmdbConfigurationException {
      final stremio = _stremio;
      if (stremio == null) rethrow;
      return stremio.episodes(seriesId, season);
    }
  }

  /// IMDb for stream/subtitle addons: Stremio catalog cache first (keyless),
  /// then TMDB external_ids.
  Future<String> imdbId(MediaRef ref) async {
    final cached = _stremio?.lookupImdbId(ref);
    if (cached != null) return cached;
    return _tmdb.imdbId(ref);
  }
}
