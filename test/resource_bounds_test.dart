import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/provider_cache.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

const _movie = MediaRef(id: 1, type: MediaType.movie);

TorrentSource _src(String id) => TorrentSource(
  id: id,
  content: _movie,
  name: 'S $id',
  uri: Uri.parse('magnet:?xt=urn:btih:$id'),
  inputType: TorrentInputType.magnet,
  providerName: 'P',
  attribution: '',
  license: '',
  provenanceUrl: Uri.parse('https://example.com'),
);

void main() {
  test('repeated browsing stays bounded (LRU cache)', () async {
    final cache = ExpiringCache<String, int>(maxEntries: 5, ttl: const Duration(minutes: 5));
    for (var i = 0; i < 50; i++) {
      await cache.get('key-$i', () async => i);
    }
    expect(cache.length, 5);
  });

  test('long playback keeps only latest stats (no accumulation)', () async {
    final engine = _StreamingEngine();
    final service = StreamingService(engine, _EmptyCache());
    await service.start(_src('a' * 40));
    // Simulate 500 stats ticks.
    for (var i = 0; i < 500; i++) {
      engine.emit(TorrentStats(downloadedBytes: i * 1000, totalBytes: 1000000, downloadRate: 1000));
      await Future<void>.delayed(Duration.zero);
    }
    expect(service.state.stats.downloadedBytes, 499 * 1000);
    await service.dispose();
  });

  test('repeated source starts do not leak handles', () async {
    final engine = _StreamingEngine();
    final service = StreamingService(engine, _EmptyCache());
    for (var i = 0; i < 10; i++) {
      await service.start(_src('${'a' * 39}$i'));
      await service.stop();
    }
    expect(engine.liveHandles, 0);
    await service.dispose();
  });
}

class _EmptyCache extends PlaybackCacheStore {
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<void> record(TorrentSource s, TorrentFileEntry f, {required bool complete, required int byteSize}) async {}
}

class _StreamingEngine implements TorrentEngine {
  final _controller = StreamController<TorrentStats>.broadcast();
  int liveHandles = 0;
  void emit(TorrentStats s) => _controller.add(s);
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    liveHandles++;
    return TorrentHandle('h$liveHandles');
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async => const [
    TorrentFileEntry(index: 0, name: 'm.mp4', size: 100, isStreamable: true),
  ];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => _controller.stream;
  @override
  Future<TorrentPlaybackStream> startStream(TorrentHandle handle, TorrentFileEntry file) async =>
      TorrentPlaybackStream(id: 's', uri: Uri.parse('http://127.0.0.1:1/x'), file: file);
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    if (liveHandles > 0) liveHandles--;
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}
