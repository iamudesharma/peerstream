abstract final class AppConfig {
  static const tmdbToken = String.fromEnvironment(
    'TMDB_READ_TOKEN',
    defaultValue: 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJjYmZkYWJhYzQ5Y2ViZGFkNmI0ZmMyYmFkZmYwMTY5YyIsIm5iZiI6MTYwMjU3NjgwNi45NzYsInN1YiI6IjVmODU2MWE2OGUyYmE2MDAzNWVhOTU0ZiIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.PZ2BmC7zrsvQL8yPMMLnWVUyJLqOASHe7WApq0g_4Hs',
  );
  static const tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const tmdbImageBaseUrl = 'https://image.tmdb.org/t/p';

  static bool get hasTmdbToken => tmdbToken.trim().isNotEmpty;

  /// Public BeamUp instance of the Streaming Catalogs addon (USA catalogue).
  /// Override with `--dart-define=STREAMING_CATALOGS_MANIFEST_URL=...`.
  static const streamingCatalogsManifestUrl = String.fromEnvironment(
    'STREAMING_CATALOGS_MANIFEST_URL',
    defaultValue:
        'https://7a82163c306e-stremio-netflix-catalog-addon.baby-beamup.club/manifest.json',
  );

  /// Cinemeta provides keyless meta/episodes/search to complement catalogs.
  static const cinemetaBaseUrl = String.fromEnvironment(
    'CINEMETA_BASE_URL',
    defaultValue: 'https://v3-cinemeta.strem.io',
  );

  static const streamingCatalogsEnabled = bool.fromEnvironment(
    'STREAMING_CATALOGS_ENABLED',
    defaultValue: true,
  );

  static bool get hasStreamingCatalogs =>
      streamingCatalogsEnabled &&
      streamingCatalogsManifestUrl.trim().isNotEmpty;
}
