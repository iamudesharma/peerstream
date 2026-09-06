import 'media_item.dart';

const myListMaxEntries = 100;

class SavedItem {
  const SavedItem({
    required this.key,
    required this.media,
    required this.title,
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.rating = 0,
    required this.addedAt,
  });

  final String key;
  final MediaRef media;
  final String title;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final double rating;
  final DateTime addedAt;

  factory SavedItem.fromMediaItem(MediaItem item) {
    return SavedItem(
      key: item.ref.routeKey,
      media: item.ref,
      title: item.title,
      overview: item.overview,
      posterPath: item.posterPath,
      backdropPath: item.backdropPath,
      releaseDate: item.releaseDate,
      rating: item.rating,
      addedAt: DateTime.now(),
    );
  }

  MediaItem toMediaItem() {
    return MediaItem(
      id: media.id,
      type: media.type,
      title: title,
      overview: overview,
      posterPath: posterPath,
      backdropPath: backdropPath,
      releaseDate: releaseDate,
      rating: rating,
    );
  }

  SavedItem copyWithAddedAt(DateTime addedAt) {
    return SavedItem(
      key: key,
      media: media,
      title: title,
      overview: overview,
      posterPath: posterPath,
      backdropPath: backdropPath,
      releaseDate: releaseDate,
      rating: rating,
      addedAt: addedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'mediaId': media.id,
    'mediaType': media.type.name,
    'title': title,
    'overview': overview,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'releaseDate': releaseDate,
    'rating': rating,
    'addedAt': addedAt.millisecondsSinceEpoch,
  };

  factory SavedItem.fromJson(Map<String, dynamic> json) {
    final id = json['mediaId'];
    if (id is! int) throw const FormatException('Invalid saved item.');
    final media = MediaRef(
      id: id,
      type: MediaType.parse(json['mediaType'] as String? ?? 'movie'),
    );
    final addedAt = json['addedAt'];
    return SavedItem(
      key: (json['key'] as String?) ?? media.routeKey,
      media: media,
      title: (json['title'] as String?) ?? 'Untitled',
      overview: (json['overview'] as String?) ?? '',
      posterPath: json['posterPath'] as String?,
      backdropPath: json['backdropPath'] as String?,
      releaseDate: json['releaseDate'] as String?,
      rating: (json['rating'] as num?)?.toDouble() ?? 0,
      addedAt: addedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(addedAt)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SavedItem &&
        other.key == key &&
        other.media == media &&
        other.title == title &&
        other.overview == overview &&
        other.posterPath == posterPath &&
        other.backdropPath == backdropPath &&
        other.releaseDate == releaseDate &&
        other.rating == rating &&
        other.addedAt == addedAt;
  }

  @override
  int get hashCode => Object.hash(
    key,
    media,
    title,
    overview,
    posterPath,
    backdropPath,
    releaseDate,
    rating,
    addedAt,
  );
}

List<SavedItem> normalizeMyList(List<SavedItem> items) {
  final latest = <String, SavedItem>{};
  for (final item in items) {
    final existing = latest[item.key];
    if (existing == null || item.addedAt.isAfter(existing.addedAt)) {
      latest[item.key] = item;
    }
  }
  final sorted = latest.values.toList();
  sorted.sort((a, b) => b.addedAt.compareTo(a.addedAt));
  if (sorted.length > myListMaxEntries) {
    return sorted.sublist(0, myListMaxEntries);
  }
  return sorted;
}
