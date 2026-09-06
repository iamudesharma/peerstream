import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/season.dart';
import '../services/tmdb/tmdb_service.dart';

class MediaRepository {
  const MediaRepository(this._tmdb);
  final TmdbService _tmdb;

  Future<List<MediaItem>> trendingMovies() => _tmdb.trending(MediaType.movie);
  Future<List<MediaItem>> trendingSeries() => _tmdb.trending(MediaType.tv);
  Future<List<MediaItem>> popularMovies() => _tmdb.popular(MediaType.movie);
  Future<List<MediaItem>> search(String query) => _tmdb.search(query);
  Future<List<MediaItem>> discover(
    MediaType type,
    int genreId, {
    int page = 1,
  }) => _tmdb.discover(type, genreId, page: page);
  Future<MediaDetails> details(MediaRef ref) => _tmdb.details(ref);
  Future<List<Episode>> episodes(int seriesId, int season) =>
      _tmdb.episodes(seriesId, season);
}
