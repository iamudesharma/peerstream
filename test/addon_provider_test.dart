import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/torrent/addon_provider.dart';
import 'package:peerstream/services/torrent/torrent_provider.dart';

const movie = MediaRef(id: 10378, type: MediaType.movie);
const series = MediaRef(id: 1, type: MediaType.tv);
const hash = '0123456789abcdef0123456789abcdef01234567';
void main() {
  test(
    'matches exact episode, preserves file index, tracker and provider headers',
    () async {
      final paths = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              paths.add(o.uri.path);
              h.resolve(
                Response(
                  requestOptions: o,
                  data: o.path.endsWith('manifest.json')
                      ? {
                          'name': 'Test addon',
                          'types': ['movie', 'series'],
                          'resources': ['stream'],
                        }
                      : {
                          'streams': [
                            {
                              'infoHash': hash,
                              'fileIdx': 7,
                              'sources': ['tracker:udp://tracker.example:80'],
                              'behaviorHints': {'filename': 'show.s02e03.mkv'},
                              'seeders': 12,
                            },
                            {
                              'url': 'https://video.example/episode.m3u8',
                              'behaviorHints': {
                                'proxyHeaders': {
                                  'request': {
                                    'Referer': 'https://video.example',
                                  },
                                },
                              },
                            },
                            {'externalUrl': 'https://example.com/watch'},
                          ],
                        },
                ),
              );
            },
          ),
        );
      final provider = AddonTorrentProvider(
        manifestUrl: Uri.parse('https://addon.example/config/manifest.json'),
        resolveImdbId: (_) async => 'tt1234567',
        dio: dio,
      );
      final sources = await provider.findSources(
        series,
        seasonNumber: 2,
        episodeNumber: 3,
      );
      expect(paths.last, '/config/stream/series/tt1234567:2:3.json');
      expect(sources, hasLength(2));
      expect(sources.first.fileIndex, 7);
      expect(sources.first.seeds, 12);
      expect(
        sources.first.uri.queryParameters['tr'],
        'udp://tracker.example:80',
      );
      expect(sources.last.headers['Referer'], 'https://video.example');
      expect(sources.last.inputType, TorrentInputType.directUrl);
    },
  );

  test(
    'all providers run concurrently, retain alternatives and isolate failure',
    () async {
      final gate = Completer<void>();
      var called = 0;
      final provider = AddonTorrentProvider(
        manifestUrl: Uri.parse('https://example.com/manifest.json'),
        resolveImdbId: (_) async => 'tt1',
      );
      final source = provider.parseStream(
        {'infoHash': hash, 'fileIdx': 1},
        movie,
        providerName: 'First',
      )!;
      Future<List<TorrentSource>> run() async {
        called++;
        if (called == 2) gate.complete();
        await gate.future;
        return [source, source];
      }

      final results = await searchAllProviders([
        FakeProvider('First', run),
        FakeProvider('Second', run),
        FakeProvider('Broken', () async => throw StateError('offline')),
      ], movie);
      expect(called, 2);
      expect(results[0].sources, hasLength(1));
      expect(results[1].sources, hasLength(1));
      expect(results[2].error, isNotNull);
    },
  );

  test(
    'slow provider times out without discarding completed results',
    () async {
      final results = await searchAllProviders(
        [
          FakeProvider('Slow', () => Completer<List<TorrentSource>>().future),
          FakeProvider('Empty', () async => []),
        ],
        movie,
        timeout: const Duration(milliseconds: 10),
      );
      expect(results.first.error, isNotNull);
      expect(results.last.error, isNull);
    },
  );

  test('reads Torrentio seed, size and indexer metadata without inventing unknowns', () {
    final p = AddonTorrentProvider(
      manifestUrl: Uri.parse('https://torrentio.strem.fun/manifest.json'),
      resolveImdbId: (_) async => 'tt1',
    );
    final s = p.parseStream(
      {'infoHash': hash, 'title': 'Movie\n👤 0 💾 531.71 MB ⚙️ MagnetDL'},
      movie,
      providerName: 'Torrentio',
    )!;
    expect(s.seeds, 0);
    expect(s.providerName, 'MagnetDL');
    expect(s.sizeBytes, (531.71 * 1024 * 1024).round());
    expect(
      p.parseStream({'infoHash': hash}, movie, providerName: 'Test')!.seeds,
      isNull,
    );
  });
}

class FakeProvider implements TorrentProvider {
  FakeProvider(this.name, this.run);
  @override
  final String name;
  final Future<List<TorrentSource>> Function() run;
  @override
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
    CancelToken? cancelToken,
  }) => run();
}
