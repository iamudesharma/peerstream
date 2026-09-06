import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

final source = TorrentSource(
  id: 'demo',
  content: MediaRef(id: 10378, type: MediaType.movie),
  name: 'Demo',
  uri: Uri.parse('magnet:?xt=urn:btih:demo'),
  inputType: TorrentInputType.magnet,
  providerName: 'Test',
  attribution: 'Test',
  license: 'CC BY 3.0',
  provenanceUrl: Uri.parse('https://example.com'),
);

void main() {
  test('slow startup schedules a five-minute stall timeout', () async {
    final service = StreamingService(FakeTorrentEngine(), _EmptyCacheStore());
    Duration? delay;
    void Function()? expire;
    await runZoned(
      () => service.start(source),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == Duration.zero) {
            return parent.createTimer(zone, duration, callback);
          }
          delay = duration;
          expire = callback;
          return _CapturedTimer();
        },
      ),
    );
    expect(delay, const Duration(minutes: 5));
    expect(service.state.phase, isNot(StreamingPhase.error));
    final failed = service.states.firstWhere(
      (s) => s.phase == StreamingPhase.error,
    );
    expire!();
    expect((await failed).message, contains('five minutes'));
    await service.dispose();
  });

  test('coordinates metadata, stream creation, and cleanup', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine);
    await service.start(source);
    expect(service.state.phase, StreamingPhase.buffering);
    expect(service.state.playback?.uri.host, '127.0.0.1');
    expect(engine.startedFile?.name, 'movie.mp4');
    await service.stop();
    expect(engine.stopped, isTrue);
    await service.dispose();
  });

  test('reports unsupported platforms without adding a torrent', () async {
    final engine = FakeTorrentEngine(supported: false);
    final service = StreamingService(engine);
    await service.start(source);
    expect(service.state.phase, StreamingPhase.unsupported);
    expect(engine.added, isFalse);
    await service.dispose();
  });

  test('stop keeps downloaded files for faster replay', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine);
    await service.start(source);
    await service.stop();
    expect(engine.deleteFilesFlag, isFalse);
    await service.dispose();
  });

  test('warmUp initializes the engine without throwing', () async {
    final service = StreamingService(FakeTorrentEngine());
    await service.warmUp();
    await service.dispose();
  });

  test('uses a complete cached file without adding a torrent', () async {
    final engine = FakeTorrentEngine();
    final cache = _CachedPlaybackStore(
      PlaybackCacheEntry(
        cacheKey: 'cached-demo',
        source: source,
        file: const TorrentFileEntry(
          index: 0,
          name: 'movie.mp4',
          size: 1000,
          isStreamable: true,
        ),
        filePath: '/tmp/cached-movie.mp4',
        complete: true,
        byteSize: 1000,
        lastUsedAt: DateTime(2026),
      ),
    );
    final service = StreamingService(engine, cache);

    await service.start(source);

    expect(engine.added, isFalse);
    expect(service.state.phase, StreamingPhase.ready);
    expect(service.state.origin, PlaybackOrigin.cache);
    expect(service.state.playback?.uri.scheme, 'file');
    await service.dispose();
  });
}

class _CapturedTimer implements Timer {
  @override
  bool isActive = true;
  @override
  int get tick => 0;
  @override
  void cancel() => isActive = false;
}

class _EmptyCacheStore extends PlaybackCacheStore {
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;

  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
  }) async {}
}

class _CachedPlaybackStore extends PlaybackCacheStore {
  _CachedPlaybackStore(this.entry);
  final PlaybackCacheEntry entry;

  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => entry;
}

class FakeTorrentEngine implements TorrentEngine {
  FakeTorrentEngine({this.supported = true});
  final bool supported;
  bool added = false;
  bool stopped = false;
  bool? deleteFilesFlag;
  TorrentFileEntry? startedFile;
  @override
  bool get isSupported => supported;
  @override
  String? get unsupportedReason =>
      supported ? null : 'Unsupported test platform';
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    added = true;
    return const TorrentHandle('1');
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async =>
      const [
        TorrentFileEntry(
          index: 0,
          name: 'movie.mp4',
          size: 1000,
          isStreamable: true,
        ),
      ];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) =>
      Stream<TorrentStats>.fromIterable(const []);
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async {
    startedFile = file;
    return TorrentPlaybackStream(
      id: '2',
      uri: Uri.parse('http://127.0.0.1:9999/stream'),
      file: file,
    );
  }

  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = true}) async {
    stopped = true;
    deleteFilesFlag = deleteFiles;
  }

  @override
  Future<void> dispose() async {}
}
