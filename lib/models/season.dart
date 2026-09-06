class SeasonSummary {
  const SeasonSummary({
    required this.number,
    required this.name,
    required this.episodeCount,
    this.posterPath,
  });
  final int number;
  final String name;
  final int episodeCount;
  final String? posterPath;
}

class Episode {
  const Episode({
    required this.id,
    required this.number,
    required this.name,
    required this.overview,
    this.stillPath,
    this.runtimeMinutes,
  });
  final int id;
  final int number;
  final String name;
  final String overview;
  final String? stillPath;
  final int? runtimeMinutes;
}
