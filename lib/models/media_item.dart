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
}
