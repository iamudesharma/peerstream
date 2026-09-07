import 'package:dio/dio.dart';

import '../../core/config.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/season.dart';

class TmdbService {
  TmdbService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppConfig.tmdbBaseUrl,
              headers: {
                'Authorization': 'Bearer ${AppConfig.tmdbToken}',
                'accept': 'application/json',
              },
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;
  final Map<MediaRef, String> _imdbCache = {};

  void _requireToken() {
    if (!AppConfig.hasTmdbToken) throw const TmdbConfigurationException();
  }

  Future<List<MediaItem>> list(
    String endpoint,
    MediaType type, {
    int page = 1,
    Map<String, dynamic>? query,
  }) async {
    _requireToken();
    final response = await _dio.get<Map<String, dynamic>>(
      endpoint,
      queryParameters: {'page': page, 'language': 'en-US', ...?query},
    );
    final results = response.data?['results'] as List<dynamic>? ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .map((json) => MediaItem.fromJson(json, type))
        .toList();
  }

  Future<List<MediaItem>> trending(MediaType type, {int page = 1}) =>
      list('/trending/${type.name}/week', type, page: page);

  Future<List<MediaItem>> popular(MediaType type, {int page = 1}) =>
      list('/${type.name}/popular', type, page: page);

  Future<List<MediaItem>> discover(
    MediaType type,
    int genreId, {
    int page = 1,
  }) => list(
    '/discover/${type.name}',
    type,
    page: page,
    query: {'with_genres': genreId},
  );

  Future<List<MediaItem>> search(String query, {int page = 1}) async {
    _requireToken();
    if (query.trim().isEmpty) return const [];
    final response = await _dio.get<Map<String, dynamic>>(
      '/search/multi',
      queryParameters: {
        'query': query.trim(),
        'page': page,
        'language': 'en-US',
        'include_adult': false,
      },
    );
    final results = response.data?['results'] as List<dynamic>? ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .where((json) {
          return json['media_type'] == 'movie' || json['media_type'] == 'tv';
        })
        .map((json) {
          final type = MediaType.parse(json['media_type'] as String);
          return MediaItem.fromJson(json, type);
        })
        .toList();
  }

  Future<MediaDetails> details(MediaRef ref) async {
    if (!AppConfig.hasTmdbToken && demoItems.any((item) => item.ref == ref)) {
      return MediaDetails(
        item: demoItems.firstWhere((item) => item.ref == ref),
      );
    }
    _requireToken();
    final response = await _dio.get<Map<String, dynamic>>(
      '/${ref.type.name}/${ref.id}',
      queryParameters: {'language': 'en-US'},
    );
    final json = response.data ?? const <String, dynamic>{};
    final item = MediaItem.fromJson(json, ref.type);
    final genres = (json['genres'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((genre) => genre['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    final seasons = (json['seasons'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (season) => SeasonSummary(
            number: season['season_number'] as int? ?? 0,
            name: season['name'] as String? ?? 'Season',
            episodeCount: season['episode_count'] as int? ?? 0,
            posterPath: season['poster_path'] as String?,
          ),
        )
        .toList();
    return MediaDetails(
      item: item,
      runtimeMinutes: json['runtime'] as int?,
      genres: genres,
      seasons: seasons,
    );
  }

  Future<String> imdbId(MediaRef ref) async {
    final cached = _imdbCache[ref];
    if (cached != null) return cached;
    _requireToken();
    final response = await _dio.get<Map<String, dynamic>>(
      '/${ref.type.name}/${ref.id}/external_ids',
    );
    final id = response.data?['imdb_id'];
    if (id is! String || !RegExp(r'^tt[0-9]+$').hasMatch(id)) {
      throw StateError('This title has no IMDb ID for addon source lookup.');
    }
    _imdbCache[ref] = id;
    return id;
  }

  Future<List<Episode>> episodes(int seriesId, int seasonNumber) async {
    _requireToken();
    final response = await _dio.get<Map<String, dynamic>>(
      '/tv/$seriesId/season/$seasonNumber',
      queryParameters: {'language': 'en-US'},
    );
    return (response.data?['episodes'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => Episode(
            id: json['id'] as int,
            number: json['episode_number'] as int? ?? 0,
            name: json['name'] as String? ?? 'Episode',
            overview: json['overview'] as String? ?? '',
            stillPath: json['still_path'] as String?,
            runtimeMinutes: json['runtime'] as int?,
          ),
        )
        .toList();
  }
}

class TmdbConfigurationException implements Exception {
  const TmdbConfigurationException();
  @override
  String toString() =>
      'Add --dart-define=TMDB_READ_TOKEN=your_token to browse TMDB.';
}

const demoItems = [
  MediaItem(
    id: 10378,
    type: MediaType.movie,
    title: 'Big Buck Bunny',
    overview: 'A gentle giant rabbit turns the tables on three bullying rodents. An open movie by Blender Foundation.',
    releaseDate: '2008-04-10',
    rating: 6.5,
  ),
  MediaItem(
    id: 45745,
    type: MediaType.movie,
    title: 'Sintel',
    overview: 'A young woman crosses a perilous land while searching for a dragon she once cared for.',
    releaseDate: '2010-09-30',
    rating: 7.4,
  ),
  MediaItem(
    id: 133701,
    type: MediaType.movie,
    title: 'Tears of Steel',
    overview: 'Warriors and scientists gather in Amsterdam to save the world from destructive robots.',
    releaseDate: '2012-09-28',
    rating: 5.5,
  ),
];
