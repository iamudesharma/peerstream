import 'package:dio/dio.dart';

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../torrent/addon_provider.dart';

class OnlineSubtitle {
  const OnlineSubtitle({
    required this.id,
    required this.url,
    required this.language,
    required this.provider,
  });
  final String id;
  final Uri url;
  final String language;
  final String provider;

  String get label => '$language · $provider';
}

/// Reads the standard Stremio subtitle resource from configured addons. This
/// runs only when the viewer explicitly asks to find subtitles.
class AddonSubtitleProvider {
  AddonSubtitleProvider({required this.resolveImdbId, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ),
          );

  final Future<String> Function(MediaRef) resolveImdbId;
  final Dio _dio;

  Future<List<OnlineSubtitle>> find(
    List<String> addonUrls, {
    required TorrentSource source,
    TorrentFileEntry? file,
  }) async {
    final imdb = await resolveImdbId(source.content);
    final type = source.content.type == MediaType.movie ? 'movie' : 'series';
    final id = type == 'movie'
        ? imdb
        : '$imdb:${source.seasonNumber}:${source.episodeNumber}';
    final groups = await Future.wait(
      addonUrls.map(
        (value) => _findFromAddon(
          value,
          type: type,
          id: id,
          file: file,
        ).catchError((_) => const <OnlineSubtitle>[]),
      ),
    );
    final seen = <String>{};
    return groups.expand((group) => group).where((item) {
      return seen.add('${item.url}|${item.language}');
    }).toList();
  }

  Future<List<OnlineSubtitle>> _findFromAddon(
    String value, {
    required String type,
    required String id,
    TorrentFileEntry? file,
  }) async {
    final manifestUrl = AddonTorrentProvider.validateUrl(value);
    final manifest = (await _dio.getUri<Map<String, dynamic>>(manifestUrl))
        .data;
    if (manifest == null || !_hasSubtitleResource(manifest['resources'])) {
      return const [];
    }
    final request = manifestUrl.replace(
      pathSegments: [
        ...manifestUrl.pathSegments.take(manifestUrl.pathSegments.length - 1),
        'subtitles',
        type,
        '$id.json',
      ],
      queryParameters: {
        if (file != null && file.size > 0) 'videoSize': '${file.size}',
        if (file != null && file.name.isNotEmpty) 'filename': file.name,
      },
    );
    final response = (await _dio.getUri<Map<String, dynamic>>(request)).data;
    final rows = response?['subtitles'];
    if (rows is! List) return const [];
    final provider = manifest['name'] as String? ?? manifestUrl.host;
    return rows
        .whereType<Map>()
        .map((row) {
          final url = Uri.tryParse(row['url'] as String? ?? '');
          if (url == null || !['http', 'https'].contains(url.scheme)) {
            return null;
          }
          final language = row['lang'] as String? ?? 'Unknown language';
          return OnlineSubtitle(
            id: row['id'] as String? ?? '${provider}_${url.toString()}',
            url: url,
            language: language,
            provider: provider,
          );
        })
        .whereType<OnlineSubtitle>()
        .toList();
  }

  bool _hasSubtitleResource(dynamic resources) {
    if (resources is! List) return false;
    return resources.any(
      (resource) =>
          resource == 'subtitles' ||
          (resource is Map && resource['name'] == 'subtitles'),
    );
  }
}
