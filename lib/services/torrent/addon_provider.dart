import 'package:dio/dio.dart';

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import 'provider_cache.dart';
import 'torrent_provider.dart';

/// Stremio stream protocol: exact IMDb movie / IMDb:season:episode lookup.
class AddonTorrentProvider implements TorrentProvider {
  AddonTorrentProvider({
    required this.manifestUrl,
    required this.resolveImdbId,
    Dio? dio,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
             ),
           );

  final Uri manifestUrl;
  final Future<String> Function(MediaRef) resolveImdbId;
  final Dio _dio;

  /// Bounded, expiring manifest cache shared across provider instances.
  /// Manifests change rarely; a 10-minute TTL with 32-entry bound avoids a
  /// manifest RTT on every source search while staying fresh.
  static final ExpiringCache<String, Map<String, dynamic>?> _manifestCache =
      ExpiringCache(maxEntries: 32, ttl: const Duration(minutes: 10));

  /// Clears the shared manifest cache. Primarily for tests.
  static void clearManifestCache() => _manifestCache.clear();
  @override
  String get name => manifestUrl.host;

  static Uri validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        !uri.path.endsWith('/manifest.json') ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const FormatException(
        'Use an HTTP(S) addon URL ending in /manifest.json.',
      );
    }
    return uri;
  }

  @override
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
    CancelToken? cancelToken,
  }) async {
    final manifest = await _manifestCache.get(manifestUrl.toString(), () async {
      final response = await _dio.getUri<Map<String, dynamic>>(
        manifestUrl,
        cancelToken: cancelToken,
      );
      return response.data;
    });
    if (manifest == null) throw const FormatException('Empty addon manifest.');
    final type = content.type == MediaType.movie ? 'movie' : 'series';
    if (type == 'series' && (seasonNumber == null || episodeNumber == null)) {
      return [];
    }
    final types = manifest['types'] as List? ?? [];
    if (!types.contains(type)) return [];
    final resources = manifest['resources'] as List? ?? [];
    if (!resources.any(
      (r) =>
          r == 'stream' ||
          (r is Map &&
              r['name'] == 'stream' &&
              (r['types'] == null || (r['types'] as List).contains(type))),
    )) {
      return [];
    }
    final imdb = await resolveImdbId(content);
    if (cancelToken?.isCancelled == true) return [];
    final id = type == 'movie' ? imdb : '$imdb:$seasonNumber:$episodeNumber';
    final uri = manifestUrl.replace(
      pathSegments: [
        ...manifestUrl.pathSegments.take(manifestUrl.pathSegments.length - 1),
        'stream',
        type,
        '$id.json',
      ],
    );
    final data = (await _dio.getUri<Map<String, dynamic>>(
      uri,
      cancelToken: cancelToken,
    )).data;
    if (data?['streams'] is! List) {
      throw const FormatException(
        'Addon response is missing its streams list.',
      );
    }
    final result = <TorrentSource>[];
    for (final row in data!['streams'] as List) {
      if (row is! Map<String, dynamic>) continue;
      final source = parseStream(
        row,
        content,
        providerName: manifest['name'] as String? ?? name,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
      );
      if (source != null) result.add(source);
    }
    return result;
  }

  TorrentSource? parseStream(
    Map<String, dynamic> row,
    MediaRef content, {
    required String providerName,
    int? seasonNumber,
    int? episodeNumber,
  }) {
    final hash = row['infoHash'];
    final hints = row['behaviorHints'] is Map
        ? row['behaviorHints'] as Map
        : {};
    final fileIndex = _integer(row['fileIdx']);
    Uri? uri;
    var inputType = TorrentInputType.directUrl;
    if (hash is String && RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hash)) {
      uri = Uri(
        scheme: 'magnet',
        queryParameters: {
          'xt': 'urn:btih:${hash.toLowerCase()}',
          'tr': (row['sources'] as List? ?? [])
              .whereType<String>()
              .where((s) => s.startsWith('tracker:'))
              .map((s) => s.substring(8))
              .toList(),
        },
      );
      inputType = TorrentInputType.magnet;
    } else if (row['url'] is String) {
      uri = Uri.tryParse(row['url'] as String);
      if (uri?.scheme == 'magnet') {
        inputType = TorrentInputType.magnet;
      } else if (uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty) {
        if (uri.path.toLowerCase().endsWith('.torrent')) {
          inputType = TorrentInputType.torrentUrl;
        }
      } else {
        return null;
      }
    }
    if (uri == null) {
      return null; // External webpages and unsupported transports.
    }
    final proxy = hints['proxyHeaders'];
    final request = proxy is Map ? proxy['request'] : null;
    final headers = <String, String>{};
    if (request is Map) {
      for (final entry in request.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }
    final description =
        row['description'] as String? ?? row['title'] as String?;
    // Torrentio embeds indexer statistics in its display description.
    final torrentio = manifestUrl.host == 'torrentio.strem.fun';
    final indexer = torrentio && description != null
        ? RegExp(r'⚙️?\s*([^\n]+)').firstMatch(description)?.group(1)?.trim()
        : null;
    final seedText = torrentio && description != null
        ? RegExp(r'👤\s*(\d+)').firstMatch(description)?.group(1)
        : null;
    final sizeMatch = torrentio && description != null
        ? RegExp(r'💾\s*([0-9.]+)\s*(GB|MB|KB)').firstMatch(description)
        : null;
    final displaySize = sizeMatch == null
        ? null
        : (double.parse(sizeMatch.group(1)!) *
                  switch (sizeMatch.group(2)) {
                    'GB' => 1024 * 1024 * 1024,
                    'MB' => 1024 * 1024,
                    _ => 1024,
                  })
              .round();
    return TorrentSource(
      id: '${manifestUrl.toString()}|${content.routeKey}|$seasonNumber|$episodeNumber|$uri|$fileIndex',
      content: content,
      name: row['name'] as String? ?? providerName,
      description: description,
      uri: uri,
      inputType: inputType,
      providerName: indexer ?? providerName,
      attribution: '',
      license: '',
      provenanceUrl: manifestUrl,
      fileNameHint: hints['filename'] as String?,
      fileIndex: fileIndex,
      headers: headers,
      seeds: _integer(row['seeders'] ?? row['seeds'] ?? seedText),
      peers: _integer(row['peers']),
      sizeBytes: _integer(row['size'] ?? hints['videoSize']) ?? displaySize,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );
  }

  static int? _integer(dynamic value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed >= 0 ? parsed : null;
  }
}

class ProviderResult {
  const ProviderResult(this.name, this.sources, {this.error});
  final String name;
  final List<TorrentSource> sources;
  final String? error;
}

Future<List<ProviderResult>> searchAllProviders(
  List<TorrentProvider> providers,
  MediaRef content, {
  int? seasonNumber,
  int? episodeNumber,
  Duration timeout = const Duration(seconds: 20),
  List<CancelToken?>? cancelTokens,
}) => Future.wait(
  providers.map((provider) async {
    final token = CancelToken();
    // Track tokens so callers (Riverpod onDispose) can cancel network work.
    if (cancelTokens != null) cancelTokens.add(token);
    try {
      final sources = await provider
          .findSources(
            content,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            cancelToken: token,
          )
          .timeout(timeout);
      // Keep provider alternatives; deduplicate only identical entries per provider.
      final seen = <String>{};
      return ProviderResult(
        provider.name,
        sources
            .where(
              (s) =>
                  s.content == content &&
                  s.seasonNumber == seasonNumber &&
                  s.episodeNumber == episodeNumber &&
                  seen.add(s.id),
            )
            .toList(),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        return ProviderResult(provider.name, [], error: 'Search was cancelled.');
      }
      return ProviderResult(
        provider.name,
        [],
        error: error.response == null
            ? 'Connection failed or timed out. Check the addon URL and connection.'
            : 'Provider returned HTTP ${error.response?.statusCode}.',
      );
    } catch (_) {
      return ProviderResult(
        provider.name,
        [],
        error:
            'Source lookup failed. Check the addon configuration and title ID.',
      );
    }
  }),
);
