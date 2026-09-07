import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/streaming/source_ranking.dart';
import 'package:peerstream/services/torrent/provider_cache.dart';
import 'package:peerstream/services/torrent/source_discovery.dart';
import 'package:peerstream/services/torrent/torrent_provider.dart';

const _movie = MediaRef(id: 7, type: MediaType.movie);

TorrentSource _src(String id, {TorrentInputType type = TorrentInputType.magnet, int? seeds, String name = 'Video 1080p'}) =>
    TorrentSource(
      id: id,
      content: _movie,
      name: name,
      uri: type == TorrentInputType.directUrl
          ? Uri.parse('https://cdn.example/$id.mp4')
          : Uri.parse('magnet:?xt=urn:btih:$id'),
      inputType: type,
      providerName: 'P',
      attribution: '',
      license: '',
      provenanceUrl: Uri.parse('https://example.com'),
      seeds: seeds,
    );

void main() {
  test('fast provider emits before slow one hangs (incremental)', () async {
    final fast = _Fake('Fast', [_src('a' * 40, seeds: 5)]);
    final hanging = _Fake('Slow', null); // never completes
    final events = <IncrementalProviderState>[];
    final stream = searchProvidersIncremental(
      [fast, hanging],
      _movie,
      timeout: const Duration(milliseconds: 50),
    );
    await for (final e in stream.timeout(const Duration(seconds: 2))) {
      events.add(e);
      if (events.any((x) => x.name == 'Fast')) break;
    }
    expect(events.any((x) => x.name == 'Fast' && x.status == ProviderStatus.ready), isTrue);
  });

  test('cancel tokens abort obsolete discovery requests', () async {
    final gate = Completer<List<TorrentSource>>();
    final provider = _Cancellable(_src('b' * 40), gate);
    final tokens = <CancelToken?>[];
    final future = searchProvidersIncremental(
      [provider],
      _movie,
      timeout: const Duration(seconds: 5),
      cancelTokens: tokens,
    ).toList();
    await Future<void>.delayed(Duration.zero);
    expect(tokens, isNotEmpty);
    tokens.first?.cancel('obsolete');
    gate.complete([_src('b' * 40)]);
    final results = await future;
    // Cancelled request surfaces as error/cancelled, not a silent stale ready.
    expect(results.first.status, ProviderStatus.error);
  });

  test('ranking prefers direct, exact, compatible, seeds, quality', () {
    final direct = _src('d1', type: TorrentInputType.directUrl, seeds: 0, name: 'Movie 480p');
    final exact = TorrentSource(
      id: 'e1',
      content: _movie,
      name: 'Movie 1080p',
      uri: Uri.parse('magnet:?xt=urn:btih:${'e' * 40}'),
      inputType: TorrentInputType.magnet,
      providerName: 'P',
      attribution: '',
      license: '',
      provenanceUrl: Uri.parse('https://example.com'),
      fileIndex: 3,
      seeds: 1,
    );
    final manySeeds = _src('s1', seeds: 100, name: 'Movie CAM');
    final ranked = [manySeeds, exact, direct]..sort(compareRankedSources);
    expect(ranked.first.inputType, TorrentInputType.directUrl);
    expect(ranked[1].fileIndex, 3);
  });

  test('refreshSource prefers same id, then provider, then best', () {
    final old = _src('old-id', seeds: 1);
    final sameId = _src('old-id', seeds: 2);
    final other = _src('other', seeds: 99);
    expect(refreshSource(old, [other, sameId])?.id, 'old-id');
    final byProvider = TorrentSource(
      id: 'new',
      content: _movie,
      name: 'x',
      uri: Uri.parse('magnet:?xt=urn:btih:${'f' * 40}'),
      inputType: TorrentInputType.magnet,
      providerName: 'P',
      attribution: '',
      license: '',
      provenanceUrl: Uri.parse('https://example.com'),
    );
    expect(refreshSource(old, [byProvider])?.providerName, 'P');
    expect(refreshSource(old, []), isNull);
  });

  test('expiring cache bounds entries, expires, and deduplicates', () async {
    final cache = ExpiringCache<String, int>(maxEntries: 2, ttl: const Duration(milliseconds: 30));
    var loads = 0;
    Future<int> loader() async {
      loads++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return loads;
    }

    final results = await Future.wait([cache.get('k', loader), cache.get('k', loader)]);
    expect(results[0], results[1]);
    expect(loads, 1);
    await cache.get('a', () async => 1);
    await cache.get('b', () async => 2);
    await cache.get('c', () async => 3);
    expect(cache.length, 2);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    loads = 0;
    await cache.get('a', loader);
    expect(loads, 1); // expired
  });

  test('single flight shares concurrent torrent adds', () async {
    final flight = SingleFlight();
    var runs = 0;
    Future<int> work() async {
      runs++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return 42;
    }

    final results = await Future.wait([flight.run('k', work), flight.run('k', work)]);
    expect(results, [42, 42]);
    expect(runs, 1);
  });
}

class _Fake implements TorrentProvider {
  _Fake(this.name, this.result);
  @override
  final String name;
  final List<TorrentSource>? result;
  @override
  Future<List<TorrentSource>> findSources(MediaRef c, {int? seasonNumber, int? episodeNumber, CancelToken? cancelToken}) {
    if (result == null) return Completer<List<TorrentSource>>().future;
    return Future.value(result);
  }
}

class _Cancellable implements TorrentProvider {
  _Cancellable(this.source, this.gate);
  final TorrentSource source;
  final Completer<List<TorrentSource>> gate;
  @override
  String get name => 'Cancellable';
  @override
  Future<List<TorrentSource>> findSources(MediaRef c, {int? seasonNumber, int? episodeNumber, CancelToken? cancelToken}) async {
    final result = await gate.future;
    if (cancelToken?.isCancelled == true) {
      throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.cancel);
    }
    return result;
  }
}
