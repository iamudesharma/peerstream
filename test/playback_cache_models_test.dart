import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/playback/torrent_cache_identity.dart';

void main() {
  final source = TorrentSource(
    id: 'source',
    content: MediaRef(id: 42, type: MediaType.movie),
    name: 'Open movie',
    uri: Uri.parse(
      'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&tr=udp%3A%2F%2Fone',
    ),
    inputType: TorrentInputType.magnet,
    providerName: 'Legal provider',
    attribution: 'Attribution',
    license: 'CC BY',
    provenanceUrl: Uri.parse('https://example.com'),
    fileIndex: 3,
    headers: const {'Authorization': 'Bearer test'},
  );

  test('uses the torrent info hash regardless of tracker order', () {
    final reordered = TorrentSource(
      id: 'different source id',
      content: source.content,
      name: source.name,
      uri: Uri.parse(
        'magnet:?tr=udp%3A%2F%2Ftwo&xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      ),
      inputType: TorrentInputType.magnet,
      providerName: source.providerName,
      attribution: source.attribution,
      license: source.license,
      provenanceUrl: source.provenanceUrl,
    );

    expect(torrentCacheKey(reordered), torrentCacheKey(source));
  });

  test('cache entry keeps source details and selected file', () {
    final entry = PlaybackCacheEntry(
      cacheKey: torrentCacheKey(source),
      source: source,
      file: const TorrentFileEntry(
        index: 3,
        name: 'movies/open.mp4',
        size: 100,
        isStreamable: true,
      ),
      filePath: '/cache/open.mp4',
      complete: true,
      byteSize: 100,
      lastUsedAt: DateTime(2026),
    );

    final restored = PlaybackCacheEntry.fromJson(entry.toJson());

    expect(restored.source.uri, source.uri);
    expect(restored.source.headers, source.headers);
    expect(restored.file.index, 3);
    expect(restored.complete, isTrue);
  });
}
