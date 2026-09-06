import '../../models/media_item.dart';
import '../../models/torrent_models.dart';

/// In-process replacement for a separate torrent-search backend.
///
/// This API ships in the Flutter bundle and exposes only reviewed legal sources.
/// It intentionally performs no web scraping and makes no network requests.
class BundledLegalTorrentApi {
  const BundledLegalTorrentApi();

  static const providerKey = 'legal-open-movies';

  static final List<TorrentSource> _catalog = [
    _source(
      id: 'bbb-webtorrent',
      tmdbId: 10378,
      title: 'Big Buck Bunny',
      fileHint: 'big buck bunny',
      torrent: 'big-buck-bunny.torrent',
    ),
    _source(
      id: 'sintel-webtorrent',
      tmdbId: 45745,
      title: 'Sintel',
      fileHint: 'sintel',
      torrent: 'sintel.torrent',
    ),
    _source(
      id: 'tears-of-steel-webtorrent',
      tmdbId: 133701,
      title: 'Tears of Steel',
      fileHint: 'tears of steel',
      torrent: 'tears-of-steel.torrent',
    ),
  ];

  /// Compatibility entry point for the archived API's route shape:
  /// `/api/{provider}/{query}/{page?}`.
  Future<Map<String, dynamic>> handlePath(String path) async {
    final segments = Uri.parse(path).pathSegments;
    if (segments.length < 3 || segments.first != 'api') {
      throw const FormatException('Expected /api/{provider}/{query}/{page?}.');
    }
    final page = segments.length > 3 ? int.tryParse(segments[3]) : 1;
    if (page == null) throw const FormatException('Page must be a number.');
    return (await search(
      provider: segments[1],
      query: Uri.decodeComponent(segments[2]),
      page: page,
    )).toJson();
  }

  Future<TorrentApiResponse> search({
    required String query,
    String provider = providerKey,
    int page = 1,
    int pageSize = 20,
  }) async {
    _validateProvider(provider);
    if (page < 1) throw const FormatException('Page must be at least 1.');
    if (pageSize < 1 || pageSize > 50) {
      throw const FormatException('Page size must be between 1 and 50.');
    }

    final normalizedQuery = _normalize(query);
    final matches = _catalog
        .where((source) {
          return normalizedQuery.isEmpty ||
              _normalize(source.name).contains(normalizedQuery) ||
              _normalize(source.fileNameHint ?? '').contains(normalizedQuery);
        })
        .toList(growable: false);
    final start = (page - 1) * pageSize;
    final items = start >= matches.length
        ? const <TorrentSource>[]
        : matches.sublist(start, (start + pageSize).clamp(0, matches.length));
    return TorrentApiResponse(
      provider: providerKey,
      query: query,
      page: page,
      pageSize: pageSize,
      total: matches.length,
      sources: items,
    );
  }

  Future<List<TorrentSource>> findByContent(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
  }) async {
    if (content.type != MediaType.movie ||
        seasonNumber != null ||
        episodeNumber != null) {
      return const [];
    }
    return _catalog
        .where((source) => source.content == content)
        .toList(growable: false);
  }

  void _validateProvider(String provider) {
    final normalized = _normalize(provider);
    if (normalized != providerKey && normalized != 'all') {
      throw UnknownCatalogProviderException(provider);
    }
  }

  static String _normalize(String value) => value.trim().toLowerCase();

  static TorrentSource _source({
    required String id,
    required int tmdbId,
    required String title,
    required String fileHint,
    required String torrent,
  }) {
    return TorrentSource(
      id: id,
      content: MediaRef(id: tmdbId, type: MediaType.movie),
      name: title,
      uri: Uri.parse('https://webtorrent.io/torrents/$torrent'),
      inputType: TorrentInputType.torrentUrl,
      providerName: 'WebTorrent Free Torrents',
      attribution: 'Blender Foundation open movie',
      license: 'Creative Commons Attribution 3.0',
      provenanceUrl: Uri.parse('https://webtorrent.io/free-torrents'),
      fileNameHint: fileHint,
    );
  }
}

class TorrentApiResponse {
  const TorrentApiResponse({
    required this.provider,
    required this.query,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.sources,
  });

  final String provider;
  final String query;
  final int page;
  final int pageSize;
  final int total;
  final List<TorrentSource> sources;

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'query': query,
    'page': page,
    'pageSize': pageSize,
    'total': total,
    'results': sources.map(_sourceToJson).toList(growable: false),
  };

  static Map<String, dynamic> _sourceToJson(TorrentSource source) => {
    'id': source.id,
    'name': source.name,
    'tmdbId': source.content.id,
    'mediaType': source.content.type.name,
    'torrentUrl': source.uri.toString(),
    'inputType': source.inputType.name,
    'provider': source.providerName,
    'attribution': source.attribution,
    'license': source.license,
    'provenanceUrl': source.provenanceUrl.toString(),
    'fileNameHint': source.fileNameHint,
  };
}

class UnknownCatalogProviderException implements Exception {
  const UnknownCatalogProviderException(this.provider);
  final String provider;

  @override
  String toString() => 'Unknown bundled torrent provider: $provider.';
}
