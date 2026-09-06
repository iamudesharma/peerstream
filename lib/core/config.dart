abstract final class AppConfig {
  static const tmdbToken = String.fromEnvironment(
    'TMDB_READ_TOKEN',
    defaultValue: '',
  );
  static const tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const tmdbImageBaseUrl = 'https://image.tmdb.org/t/p';

  static bool get hasTmdbToken => tmdbToken.trim().isNotEmpty;
}
