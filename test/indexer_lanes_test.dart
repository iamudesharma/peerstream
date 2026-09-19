import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/providers/app_providers.dart';
import 'package:peerstream/services/torrent/provider_catalog.dart';
import 'package:peerstream/services/torrent/source_discovery.dart';
import 'package:peerstream/services/torrent/source_policy.dart';
import 'package:peerstream/services/torrent/torrent_provider.dart';

const _movie = MediaRef(id: 7, type: MediaType.movie);

TorrentSource _src(String id, String indexer) => TorrentSource(
  id: id,
  content: _movie,
  name: 'Video 1080p',
  uri: Uri.parse('magnet:?xt=urn:btih:$id'),
  inputType: TorrentInputType.magnet,
  providerName: indexer,
  attribution: '',
  license: '',
  provenanceUrl: Uri.parse('https://torrentio.strem.fun/manifest.json'),
);

void main() {
  group('splitIndexerLanes', () {
    test('non-Torrentio providers pass through untouched', () {
      final sources = [_src('a' * 40, 'Comet')];
      final lanes = splitIndexerLanes('comet.elfhosted.com', sources);
      expect(lanes, hasLength(1));
      expect(lanes.single.name, 'comet.elfhosted.com');
      expect(lanes.single.sources, sources);
    });

    test('Torrentio splits into one lane per indexer', () {
      final lanes = splitIndexerLanes('torrentio.strem.fun', [
        _src('a' * 40, 'YTS'),
        _src('b' * 40, 'YTS'),
        _src('c' * 40, '1337x'),
        _src('d' * 40, 'SomeNewIndexer'),
      ]);
      final byName = {for (final l in lanes) l.name: l.sources.length};
      expect(byName['YTS'], 2);
      expect(byName['1337x'], 1);
      expect(byName['SomeNewIndexer'], 1);
      // Supported-but-absent indexers get no empty lane.
      expect(byName.containsKey('EZTV'), isFalse);
      expect(byName.containsKey('RARBG'), isFalse);
    });

    test('empty Torrentio result yields no lanes', () {
      expect(splitIndexerLanes('torrentio.strem.fun', const []), isEmpty);
    });
  });

  group('source discovery tabs', () {
    test('Torrentio expands into indexer tabs in the discovery state',
        () async {
      final container = ProviderContainer(
        overrides: [
          addonUrlsProvider.overrideWith(_EmptyAddonUrls.new),
          sourcePolicyProvider.overrideWith(
            (ref) async => const SourcePolicy(),
          ),
          torrentProvider.overrideWithValue(
            _FakeTorrentio([
              _src('a' * 40, 'YTS'),
              _src('b' * 40, '1337x'),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final request = (media: _movie, season: null, episode: null);
      final states = <IncrementalDiscoveryState>[];
      final sub = container.listen(
        sourceDiscoveryProvider(request),
        (_, next) => next.whenData(states.add),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sub.close();
      expect(states, isNotEmpty);
      expect(states.last.isComplete, isTrue);
      final lanes = states.last.providers;
      expect(lanes.containsKey('torrentio.strem.fun'), isFalse);
      expect(lanes['YTS']?.sources, hasLength(1));
      expect(lanes['1337x']?.sources, hasLength(1));
      expect(states.last.allSources, hasLength(2));
    });

    test('non-Torrentio providers keep their own lane', () async {
      final container = ProviderContainer(
        overrides: [
          addonUrlsProvider.overrideWith(_EmptyAddonUrls.new),
          sourcePolicyProvider.overrideWith(
            (ref) async => const SourcePolicy(),
          ),
          torrentProvider.overrideWithValue(
            _FakeNamed('comet.elfhosted.com', [_src('a' * 40, 'Comet')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final request = (media: _movie, season: null, episode: null);
      final states = <IncrementalDiscoveryState>[];
      final sub = container.listen(
        sourceDiscoveryProvider(request),
        (_, next) => next.whenData(states.add),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sub.close();
      expect(states.last.isComplete, isTrue);
      expect(
        states.last.providers['comet.elfhosted.com']?.sources,
        hasLength(1),
      );
    });
  });
}

class _EmptyAddonUrls extends AddonUrls {
  @override
  Future<List<String>> build() async => const [];
}

class _FakeTorrentio implements TorrentProvider {
  _FakeTorrentio(this.sources);
  final List<TorrentSource> sources;
  @override
  String get name => 'torrentio.strem.fun';
  @override
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
    CancelToken? cancelToken,
  }) async => sources;
}

class _FakeNamed implements TorrentProvider {
  _FakeNamed(this.name, this.sources);
  @override
  final String name;
  final List<TorrentSource> sources;
  @override
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
    CancelToken? cancelToken,
  }) async => sources;
}
