import 'package:dio/dio.dart';

import '../../core/config.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/season.dart';

/// A platform row exposed by the Streaming Catalogs addon.
class StremioCatalog {
  const StremioCatalog({
    required this.id,
    required this.type,
    required this.name,
  });

  final String id;
  final MediaType type;
  final String name;

  String get title => type == MediaType.movie ? '$name Movies' : '$name Series';
}

/// Keyless metadata source backed by the public Streaming Catalogs addon
/// (USA default) for browse rows plus Cinemeta for details/episodes/search.
///
/// No API key is required. The addon server aggregates JustWatch/Cinemeta and
/// serves `catalog/{type}/{id}.json` with embedded metas containing both
/// `moviedb_id` and `imdb_id`.
class StremioCatalogService {
  StremioCatalogService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Dio _dio;

  Map<String, dynamic>? _manifest;
  final Map<MediaRef, String> _imdbByRef = {};
  final Map<int, String> _imdbByMoviedbId = {};
  final Map<MediaRef, MediaDetails> _detailsCache = {};

  static final _imdbPattern = RegExp(r'^tt[0-9]+$');

  Uri get _manifestUri => Uri.parse(AppConfig.streamingCatalogsManifestUrl);
  Uri get _catalogBase => _manifestUri.replace(
    pathSegments: [
      ..._manifestUri.pathSegments.take(
        _manifestUri.pathSegments.length - 1,
      ),
    ],
  );

  Uri _cinemetaUri(List<String> segments) {
    final base = Uri.parse(AppConfig.cinemetaBaseUrl);
    return base.replace(
      pathSegments: [...base.pathSegments, ...segments],
    );
  }

  Future<Map<String, dynamic>> manifest() async {
    final cached = _manifest;
    if (cached != null) return cached;
    final response = await _dio.getUri<Map<String, dynamic>>(_manifestUri);
    final data = response.data ?? const <String, dynamic>{};
    _manifest = data;
    return data;
  }

  /// Catalog rows from the manifest, defaulting to the USA platform set.
  Future<List<StremioCatalog>> catalogs() async {
    final data = await manifest();
    final rows = data['catalogs'];
    if (rows is! List) return const [];
    final result = <StremioCatalog>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['id'] as String?;
      final rawType = row['type'] as String?;
      final name = (row['name'] as String?)?.trim() ?? '';
      if (id == null || id.isEmpty || name.isEmpty) continue;
      final type = rawType == 'series'
          ? MediaType.tv
          : rawType == 'movie'
          ? MediaType.movie
          : null;
      if (type == null) continue;
      result.add(StremioCatalog(id: id, type: type, name: name));
    }
    return _preferUsaOrder(result);
  }

  /// Fetches one platform catalog and remembers imdb mappings for later
  /// stream/source lookup without TMDB.
  Future<List<MediaItem>> catalog(
    MediaType type,
    String catalogId, {
    int skip = 0,
  }) async {
    final stremioType = type == MediaType.movie ? 'movie' : 'series';
    final uri = _catalogBase.replace(
      pathSegments: [
        ..._catalogBase.pathSegments,
        'catalog',
        stremioType,
        '$catalogId.json',
      ],
      queryParameters: skip > 0 ? {'skip': '$skip'} : null,
    );
    final response = await _dio.getUri<Map<String, dynamic>>(uri);
    final metas = response.data?['metas'];
    if (metas is! List) return const [];
    final items = <MediaItem>[];
    for (final meta in metas) {
      if (meta is! Map<String, dynamic>) continue;
      try {
        final item = MediaItem.fromStremio(meta, type);
        items.add(item);
        _rememberMeta(item.ref, meta);
      } catch (_) {
        continue;
      }
    }
    return items;
  }

  /// Keyless search via Cinemeta `top` catalogs (movie + series in parallel).
  Future<List<MediaItem>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final results = await Future.wait([
      _cinemetaCatalogSearch(MediaType.movie, trimmed),
      _cinemetaCatalogSearch(MediaType.tv, trimmed),
    ]);
    final seen = <String>{};
    return results
        .expand((list) => list)
        .where((item) => seen.add(item.ref.routeKey))
        .toList();
  }

  Future<List<MediaItem>> _cinemetaCatalogSearch(
    MediaType type,
    String query,
  ) async {
    final stremioType = type == MediaType.movie ? 'movie' : 'series';
    final uri = _cinemetaUri([
      'catalog',
      stremioType,
      'top.json',
    ]).replace(queryParameters: {'search': query});
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(uri);
      final metas = response.data?['metas'];
      if (metas is! List) return const [];
      return metas.whereType<Map<String, dynamic>>().map((meta) {
        final item = MediaItem.fromStremio(meta, type);
        _rememberMeta(item.ref, meta);
        return item;
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Keyless details: full Cinemeta meta first (has seasons/videos),
  /// falling back to the lightweight cached catalog row when offline.
  Future<MediaDetails> details(MediaRef ref) async {
    final cached = _detailsCache[ref];
    // Complete cache hit: movies are complete; series need seasons.
    if (cached != null &&
        (ref.type == MediaType.movie || cached.seasons.isNotEmpty)) {
      return cached;
    }
    final imdb = _imdbByRef[ref] ?? _imdbByMoviedbId[ref.id];
    if (imdb != null && _imdbPattern.hasMatch(imdb)) {
      try {
        final fetched = await meta(imdb, ref.type);
        _detailsCache[ref] = fetched;
        return fetched;
      } catch (_) {
        // Fall through to the lightweight cached row below.
      }
    }
    if (cached != null) return cached;
    throw StateError(
      'No keyless metadata cached for ${ref.routeKey}. Open it from a streaming row or search first.',
    );
  }

  /// Fetches full Cinemeta meta (seasons/videos included for series).
  Future<MediaDetails> meta(String imdbId, MediaType type) async {
    final stremioType = type == MediaType.movie ? 'movie' : 'series';
    final uri = _cinemetaUri([
      'meta',
      stremioType,
      '$imdbId.json',
    ]);
    final response = await _dio.getUri<Map<String, dynamic>>(uri);
    final meta = response.data?['meta'];
    if (meta is! Map<String, dynamic>) {
      throw const FormatException('Cinemeta response is missing its meta.');
    }
    final item = MediaItem.fromStremio(meta, type);
    // Re-key to the requested TMDB-based ref so navigation/caches line up.
    final keyed = MediaItem(
      id: refIdFor(meta, type, fallback: item.id),
      type: type,
      title: item.title,
      overview: item.overview,
      posterPath: item.posterPath,
      backdropPath: item.backdropPath,
      releaseDate: item.releaseDate,
      rating: item.rating,
    );
    _rememberMeta(keyed.ref, meta);
    final details = MediaDetails(
      item: keyed,
      runtimeMinutes: parseRuntime(meta['runtime']),
      genres: genresOf(meta),
      seasons: seasonsOf(meta, type),
    );
    _detailsCache[keyed.ref] = details;
    return details;
  }

  /// Keyless episodes from Cinemeta videos.
  Future<List<Episode>> episodes(int seriesId, int seasonNumber) async {
    final ref = MediaRef(id: seriesId, type: MediaType.tv);
    final imdb = _imdbByRef[ref] ?? _imdbByMoviedbId[seriesId];
    if (imdb == null || !_imdbPattern.hasMatch(imdb)) {
      throw StateError(
        'No keyless episode data cached for tv/$seriesId. Open it from a streaming row or search first.',
      );
    }
    final videos = await _videos(imdb);
    return videos
        .where((video) => video.season == seasonNumber)
        .map(
          (video) => Episode(
            id: video.hashCode,
            number: video.episode,
            name: video.title,
            overview: video.overview,
          ),
        )
        .toList();
  }

  Future<List<_CinemetaVideo>> _videos(String imdbId) async {
    final uri = _cinemetaUri(['meta', 'series', '$imdbId.json']);
    final response = await _dio.getUri<Map<String, dynamic>>(uri);
    final meta = response.data?['meta'];
    if (meta is! Map<String, dynamic>) return const [];
    final videos = meta['videos'];
    if (videos is! List) return const [];
    return videos
        .whereType<Map<String, dynamic>>()
        .map(_CinemetaVideo.parse)
        .whereType<_CinemetaVideo>()
        .toList();
  }

  /// IMDb for stream/subtitle lookup without TMDB.
  String? lookupImdbId(MediaRef ref) =>
      _imdbByRef[ref] ?? _imdbByMoviedbId[ref.id];

  void rememberImdbId(MediaRef ref, String imdbId) {
    if (!_imdbPattern.hasMatch(imdbId)) return;
    _imdbByRef[ref] = imdbId;
    if (ref.id > 0) _imdbByMoviedbId[ref.id] = imdbId;
  }

  void _rememberMeta(MediaRef ref, Map<String, dynamic> meta) {
    final imdb = meta['imdb_id'] as String? ?? meta['id'] as String?;
    if (imdb is String && _imdbPattern.hasMatch(imdb)) {
      rememberImdbId(ref, imdb);
    }
    // Keep a lightweight details fallback so keyless details work offline
    // from a previously loaded row even if Cinemeta is unreachable.
    if (!_detailsCache.containsKey(ref)) {
      try {
        final item = MediaItem.fromStremio(meta, ref.type);
        final keyed = MediaItem(
          id: ref.id,
          type: ref.type,
          title: item.title,
          overview: item.overview,
          posterPath: item.posterPath,
          backdropPath: item.backdropPath,
          releaseDate: item.releaseDate,
          rating: item.rating,
        );
        _detailsCache[ref] = MediaDetails(
          item: keyed,
          runtimeMinutes: parseRuntime(meta['runtime']),
          genres: genresOf(meta),
        );
      } catch (_) {
        // Catalog rows are best-effort; ignore malformed entries.
      }
    }
  }

  static int refIdFor(
    Map<String, dynamic> meta,
    MediaType type, {
    required int fallback,
  }) {
    final moviedbId = meta['moviedb_id'];
    if (moviedbId is int && moviedbId > 0) return moviedbId;
    if (moviedbId is num) {
      final parsed = moviedbId.toInt();
      if (parsed > 0) return parsed;
    }
    if (moviedbId is String) {
      final parsed = int.tryParse(moviedbId);
      if (parsed != null && parsed > 0) return parsed;
    }
    return fallback;
  }

  static int? parseRuntime(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) {
      final match = RegExp(r'[0-9]+').firstMatch(value);
      if (match != null) return int.tryParse(match.group(0)!);
    }
    return null;
  }

  static List<String> genresOf(Map<String, dynamic> meta) {
    final raw = meta['genres'] ?? meta['genre'];
    if (raw is List) {
      return raw
          .whereType<String>()
          .map((genre) => genre.trim())
          .where((genre) => genre.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static List<SeasonSummary> seasonsOf(
    Map<String, dynamic> meta,
    MediaType type,
  ) {
    if (type != MediaType.tv) return const [];
    final videos = meta['videos'];
    if (videos is! List) return const [];
    final counts = <int, int>{};
    for (final video in videos) {
      if (video is! Map<String, dynamic>) continue;
      final season = video['season'];
      final episode = video['episode'];
      if (season is int && season > 0 && episode is int) {
        counts[season] = (counts[season] ?? 0) + 1;
      }
    }
    final seasons = counts.entries
        .map(
          (entry) => SeasonSummary(
            number: entry.key,
            name: 'Season ${entry.key}',
            episodeCount: entry.value,
          ),
        )
        .toList();
    seasons.sort((a, b) => a.number.compareTo(b.number));
    return seasons;
  }

  static List<StremioCatalog> _preferUsaOrder(List<StremioCatalog> input) {
    // Default the home screen to the familiar USA platform order while
    // keeping any extra configured catalogs afterwards.
    const order = ['nfx', 'dnp', 'hbm', 'amp', 'atp'];
    final ranked = <String, int>{
      for (var i = 0; i < order.length; i++) order[i]: i,
    };
    final sorted = [...input];
    sorted.sort((a, b) {
      final rankA = ranked[a.id] ?? 1000;
      final rankB = ranked[b.id] ?? 1000;
      if (rankA != rankB) return rankA.compareTo(rankB);
      if (a.type != b.type) return a.type == MediaType.movie ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return sorted;
  }
}

class _CinemetaVideo {
  const _CinemetaVideo({
    required this.season,
    required this.episode,
    required this.title,
    required this.overview,
  });

  final int season;
  final int episode;
  final String title;
  final String overview;

  static _CinemetaVideo? parse(Map<String, dynamic> json) {
    final season = json['season'];
    final episode = json['episode'];
    if (season is! int || episode is! int) return null;
    return _CinemetaVideo(
      season: season,
      episode: episode,
      title: (json['title'] as String?) ?? 'Episode $episode',
      overview: (json['overview'] as String?) ?? '',
    );
  }
}
