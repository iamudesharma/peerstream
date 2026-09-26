import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/torrent/addon_provider.dart';
import 'package:peerstream/services/torrent/provider_catalog.dart';
import 'package:test/test.dart';

const _movie = MediaRef(id: 7, type: MediaType.movie);

TorrentSource _src(String id, String indexer) => TorrentSource(
  id: id,
  content: _movie,
  name: 'Video 1080p',
  uri: Uri.parse('magnet:?xt=urn:btih:$id'),
  inputType: TorrentInputType.magnet,
  providerName: indexer,
  attribution: 'test',
  license: 'CC BY 3.0',
  provenanceUrl: Uri.parse('https://example.com'),
);

void main() {
  group('splitIndexerLanes', () {
    test('gives every aggregating indexer its own lane', () {
      final lanes = splitIndexerLanes('torrentio.strem.fun', [
        _src('a', 'YTS'),
        _src('b', 'YTS'),
        _src('c', 'EZTV'),
      ]);

      expect(lanes.map((l) => l.name), containsAll(<String>['YTS', 'EZTV']));
      expect(lanes.firstWhere((l) => l.name == 'YTS').sources, hasLength(2));
      expect(lanes.firstWhere((l) => l.name == 'EZTV').sources, hasLength(1));
    });

    test('leaves other providers as a single lane', () {
      final lanes = splitIndexerLanes('Some Other Addon', [
        _src('a', 'YTS'),
        _src('b', 'EZTV'),
      ]);

      expect(lanes, hasLength(1));
      expect(lanes.single.name, 'Some Other Addon');
      expect(lanes.single.sources, hasLength(2));
    });

    test('drops indexers with no sources instead of showing empty lanes', () {
      final lanes = splitIndexerLanes('torrentio.strem.fun', [
        _src('a', 'YTS'),
      ]);

      expect(lanes, hasLength(1));
      expect(lanes.single.name, 'YTS');
    });
  });

  group('addon url validation', () {
    test('splitAddonUrlLines keeps valid links and reports the rest', () {
      final split = splitAddonUrlLines(
        'https://torrentio.strem.fun/manifest.json\n'
        'not a url\n'
        'https://example.com/manifest.json/',
      );

      expect(split.valid, hasLength(2));
      expect(split.invalid, <String>['not a url']);
    });
  });
}
