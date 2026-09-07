enum MediaType {
  movie,
  tv;

  static MediaType parse(String value) => value == 'tv' ? tv : movie;
}

class MediaRef {
  const MediaRef({required this.id, required this.type});
  final int id;
  final MediaType type;

  String get routeKey => '${type.name}/$id';

  @override
  bool operator ==(Object other) =>
      other is MediaRef && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);
}

class MediaItem {
  const MediaItem({
    required this.id,
    required this.type,
    required this.title,
    required this.overview,
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.rating = 0,
    this.genreIds = const [],
  });

  final int id;
  final MediaType type;
  final String title;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final double rating;
  final List<int> genreIds;

  MediaRef get ref => MediaRef(id: id, type: type);

  factory MediaItem.fromJson(Map<String, dynamic> json, MediaType type) {
    return MediaItem(
      id: json['id'] as int,
      type: type,
      title:
          (json[type == MediaType.movie ? 'title' : 'name'] as String?) ??
          'Untitled',
      overview: (json['overview'] as String?) ?? '',
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      releaseDate:
          json[type == MediaType.movie ? 'release_date' : 'first_air_date']
              as String?,
      rating: (json['vote_average'] as num?)?.toDouble() ?? 0,
      genreIds: (json['genre_ids'] as List<dynamic>? ?? const [])
          .whereType<int>()
          .toList(),
    );
  }

  /// Maps a Stremio catalog/meta entry to a [MediaItem].
  ///
  /// Uses `moviedb_id` as the stable integer id so existing TMDB-based
  /// routing, details, My List and history keep working. Entries without a
  /// usable `moviedb_id` fall back to a stable negative id derived from the
  /// Stremio/IMDb id so they can still be browsed keylessly.
  /// `poster`/`background` are absolute URLs (JustWatch/Metahub) and are
  /// stored as-is; see `resolveImageUrl` for display handling.
  factory MediaItem.fromStremio(Map<String, dynamic> json, MediaType type) {
    final moviedbId = _intValue(json['moviedb_id']);
    final stremioId = json['id'] as String? ?? '';
    final imdbId = json['imdb_id'] as String? ?? '';
    final fallbackId = -(_stableHash(stremioId.isNotEmpty ? stremioId : imdbId));
    final id = (moviedbId != null && moviedbId > 0) ? moviedbId : fallbackId;
    return MediaItem(
      id: id,
      type: type,
      title: (json['name'] as String?) ?? 'Untitled',
      overview: (json['description'] as String?) ?? '',
      posterPath: json['poster'] as String?,
      backdropPath: json['background'] as String?,
      releaseDate: _releaseDate(json),
      rating: _rating(json),
    );
  }

  static String? _releaseDate(Map<String, dynamic> json) {
    final released = json['released'];
    if (released is String && released.isNotEmpty) {
      // "1998-10-16T00:00:00.000Z" -> "1998-10-16"
      if (released.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(released)) {
        return released.substring(0, 10);
      }
    }
    final year = json['year'];
    if (year is String && RegExp(r'^\d{4}').hasMatch(year)) {
      return year.substring(0, 4);
    }
    final releaseInfo = json['releaseInfo'];
    if (releaseInfo is String && RegExp(r'^\d{4}').hasMatch(releaseInfo)) {
      return releaseInfo.substring(0, 4);
    }
    return null;
  }

  static double _rating(Map<String, dynamic> json) {
    final raw = json['imdbRating'];
    if (raw is num) return raw.toDouble().clamp(0, 10).toDouble();
    if (raw is String && raw.isNotEmpty) {
      // Cinemeta sometimes returns "6.4/10" style values.
      final match = RegExp(r'[0-9]+(\.[0-9]+)?').firstMatch(raw);
      if (match != null) {
        return (double.tryParse(match.group(0)!) ?? 0).clamp(0, 10).toDouble();
      }
    }
    return 0;
  }

  static int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static int _stableHash(String value) {
    if (value.isEmpty) return 1;
    var hash = 7;
    for (var i = 0; i < value.length; i++) {
      hash = (hash * 31 + value.codeUnitAt(i)) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
