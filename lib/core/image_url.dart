import 'config.dart';

/// Poster/backdrop/still paths in this app are either legacy TMDB paths
/// ("/abc.jpg") or absolute URLs from keyless Stremio catalogs
/// (JustWatch / Metahub). Resolve both to a displayable URL.
String? resolveImageUrl(String? path, {String tmdbSize = 'w342'}) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  final normalized = path.startsWith('/') ? path : '/$path';
  return '${AppConfig.tmdbImageBaseUrl}/$tmdbSize$normalized';
}
