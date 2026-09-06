import 'media_item.dart';
import 'season.dart';

class MediaDetails {
  const MediaDetails({
    required this.item,
    this.runtimeMinutes,
    this.genres = const [],
    this.seasons = const [],
  });

  final MediaItem item;
  final int? runtimeMinutes;
  final List<String> genres;
  final List<SeasonSummary> seasons;
}
