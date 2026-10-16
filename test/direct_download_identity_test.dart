import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/torrent_cache_identity.dart';

TorrentSource source(Map<String, String> headers, {int episode = 1}) =>
    TorrentSource(
      id: 'same-endpoint',
      content: const MediaRef(id: -321, type: MediaType.tv),
      seasonNumber: 1,
      episodeNumber: episode,
      name: 'Original fixture',
      uri: Uri.parse('https://example.invalid/video'),
      inputType: TorrentInputType.directUrl,
      providerName: 'Fixture',
      attribution: 'Original',
      license: 'CC0',
      provenanceUrl: Uri.parse('about:blank'),
      headers: headers,
    );
void main() {
  test('direct saves isolate header variants and episodes at the same URL', () {
    final first = torrentCacheKey(source({'Authorization': 'viewer-a'}));
    expect(
      first,
      isNot(torrentCacheKey(source({'Authorization': 'viewer-b'}))),
    );
    expect(
      first,
      isNot(torrentCacheKey(source({'Authorization': 'viewer-a'}, episode: 2))),
    );
    expect(first, isNot(contains('viewer-a')));
    expect(
      torrentCacheKey(
        source({'Referer': 'fixture', 'Authorization': 'viewer-a'}),
      ),
      torrentCacheKey(
        source({'authorization': 'viewer-a', 'referer': 'fixture'}),
      ),
    );
  });
}
