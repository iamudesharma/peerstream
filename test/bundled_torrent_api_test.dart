import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/services/torrent/bundled_torrent_api.dart';

void main() {
  const api = BundledLegalTorrentApi();

  test('searches the bundled legal catalogue without a backend', () async {
    final response = await api.search(query: 'bunny');
    expect(response.total, 1);
    expect(response.sources.single.content.id, 10378);
    expect(response.sources.single.license, contains('Creative Commons'));
  });

  test('supports the legacy route shape as in-process JSON', () async {
    final json = await api.handlePath('/api/legal-open-movies/sintel/1');
    expect(json['provider'], BundledLegalTorrentApi.providerKey);
    expect(json['total'], 1);
    expect((json['results'] as List).single, containsPair('tmdbId', 45745));
  });

  test('paginates legal results deterministically', () async {
    final first = await api.search(query: '', page: 1, pageSize: 2);
    final second = await api.search(query: '', page: 2, pageSize: 2);
    expect(first.sources, hasLength(2));
    expect(second.sources, hasLength(1));
    expect(first.sources.first.id, 'bbb-webtorrent');
    expect(second.sources.first.id, 'tears-of-steel-webtorrent');
  });

  test(
    'demo catalogue does not pretend to implement remote indexers',
    () async {
      expect(
        () => api.search(query: 'anything', provider: 'yts'),
        throwsA(isA<UnknownCatalogProviderException>()),
      );
    },
  );

  test(
    'content lookup remains exact and excludes series substitutions',
    () async {
      expect(
        await api.findByContent(
          const MediaRef(id: 10378, type: MediaType.movie),
        ),
        hasLength(1),
      );
      expect(
        await api.findByContent(
          const MediaRef(id: 10378, type: MediaType.tv),
          seasonNumber: 1,
          episodeNumber: 1,
        ),
        isEmpty,
      );
    },
  );
}
