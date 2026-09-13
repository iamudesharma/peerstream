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
  test('slow startup warns early then fails after three minutes', () async {
    final service = StreamingService(FakeTorrentEngine(), _EmptyCacheStore());
    final delays = <Duration>[];
    final callbacks = <void Function()>[];
    await runZoned(
      () => service.start(source),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == Duration.zero) {
            return parent.createTimer(zone, duration, callback);
          }
          delays.add(duration);
          callbacks.add(callback);
          return _CapturedTimer();
        },
      ),
    );
    expect(delays, contains(const Duration(seconds: 25)));
    expect(delays, contains(const Duration(minutes: 3)));
    expect(service.state.phase, isNot(StreamingPhase.error));
    // Early warning keeps buffering but surfaces a hint message.
    callbacks[delays.indexOf(const Duration(seconds: 25))]();
    expect(service.state.phase, StreamingPhase.buffering);
    expect(service.state.message, contains('Still connecting'));
    final failed = service.states.firstWhere(
      (s) => s.phase == StreamingPhase.error,
    );
    callbacks[delays.indexOf(const Duration(minutes: 3))]();
    expect((await failed).message, contains('three minutes'));
    await service.dispose();
  });

  test('prefetch warms the engine without emitting player state', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine, _EmptyCacheStore());
    await service.prefetchSource(source);
    expect(engine.added, isTrue);
    expect(service.state.phase, StreamingPhase.idle);
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

  test('hints the resume region before the player seeks', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine);
    await service.start(source, startPositionMs: 30000, durationMs: 60000);
    // Halfway through a 1000-byte file.
    expect(engine.hintedByteOffset, 500);
    await service.dispose();
  });

  test('prefers learned anchors over the bitrate estimate', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine);
    await service.start(
      source,
      startPositionMs: 30000,
      durationMs: 60000,
      timeBytePoints: const [
        TimeBytePoint(positionMs: 20000, byteOffset: 300),
        TimeBytePoint(positionMs: 40000, byteOffset: 900),
      ],
    );
    // Halfway between the anchors: 300 + (900 - 300) / 2 = 600, not the
    // average-bitrate estimate of 500.
    expect(engine.hintedByteOffset, 600);
    await service.dispose();
  });

  test('refuses a cached file that belongs to another episode', () async {
    final engine = FakeTorrentEngine();
    // Entry holds file index 0; the requested episode selects file index 1.
    final cache = _CachedPlaybackStore(
      PlaybackCacheEntry(
        cacheKey: 'cached-pack',
        source: source,
        file: const TorrentFileEntry(
          index: 0,
          name: 'Show.S01E01.mkv',
          size: 1000,
          isStreamable: true,
        ),
        filePath: '/tmp/cached-e01.mkv',
        complete: true,
        byteSize: 1000,
        lastUsedAt: DateTime(2026),
      ),
    );
    final service = StreamingService(engine, cache);
    final episode = TorrentSource(
      id: 'demo',
      content: const MediaRef(id: 10378, type: MediaType.tv),
      name: 'Demo',
      uri: Uri.parse('magnet:?xt=urn:btih:demo'),
      inputType: TorrentInputType.magnet,
      providerName: 'Test',
      attribution: 'Test',
      license: 'CC BY 3.0',
      provenanceUrl: Uri.parse('https://example.com'),
      seasonNumber: 1,
      episodeNumber: 2,
      fileIndex: 1,
    );
    await service.start(episode);
    expect(engine.added, isTrue);
    expect(service.state.origin, isNot(PlaybackOrigin.cache));
    await service.dispose();
  });

  test('uses the cached file when the episode matches', () async {
    final engine = FakeTorrentEngine();
    final cache = _CachedPlaybackStore(
      PlaybackCacheEntry(
        cacheKey: 'cached-pack',
        source: source,
        file: const TorrentFileEntry(
          index: 1,
          name: 'Show.S01E02.mkv',
          size: 1000,
          isStreamable: true,
        ),
        filePath: '/tmp/cached-e02.mkv',
        complete: true,
        byteSize: 1000,
        lastUsedAt: DateTime(2026),
      ),
    );
    final service = StreamingService(engine, cache);
    final episode = TorrentSource(
      id: 'demo',
      content: const MediaRef(id: 10378, type: MediaType.tv),
      name: 'Demo',
      uri: Uri.parse('magnet:?xt=urn:btih:demo'),
      inputType: TorrentInputType.magnet,
      providerName: 'Test',
      attribution: 'Test',
      license: 'CC BY 3.0',
      provenanceUrl: Uri.parse('https://example.com'),
      seasonNumber: 1,
      episodeNumber: 2,
      fileIndex: 1,
    );
    await service.start(episode);
    expect(engine.added, isFalse);
    expect(service.state.origin, PlaybackOrigin.cache);
    await service.dispose();
  });

  test('skips the resume hint when duration is unknown', () async {
    final engine = FakeTorrentEngine();
    final service = StreamingService(engine);
    await service.start(source, startPositionMs: 30000);
    expect(engine.hintedByteOffset, isNull);
    await service.dispose();
  });

  test('resumeByteOffset maps position to bytes', () {
    expect(
      resumeByteOffset(positionMs: 30000, durationMs: 60000, fileSize: 1000),
      500,
    );
    expect(
      resumeByteOffset(positionMs: 0, durationMs: 60000, fileSize: 1000),
      0,
    );
    expect(
      resumeByteOffset(positionMs: 60000, durationMs: 60000, fileSize: 1000),
      1000,
    );
  });

  test('resumeByteOffset clamps and rejects invalid inputs', () {
    expect(
      resumeByteOffset(positionMs: 90000, durationMs: 60000, fileSize: 1000),
      1000,
    );
    expect(
      resumeByteOffset(positionMs: 30000, durationMs: 0, fileSize: 1000),
      0,
    );
    expect(
      resumeByteOffset(positionMs: 30000, durationMs: 60000, fileSize: 0),
      0,
    );
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
    bool preserveComplete = false,
  }) async {}
}

class _CachedPlaybackStore extends PlaybackCacheStore {
  _CachedPlaybackStore(this.entry);
  final PlaybackCacheEntry entry;

  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => entry;
}

class FakeTorrentEngine implements TorrentEngine, StreamPositionController {
  FakeTorrentEngine({this.supported = true});
  final bool supported;
  bool added = false;
  bool stopped = false;
  bool? deleteFilesFlag;
  TorrentFileEntry? startedFile;
  int? hintedByteOffset;
  int? hintedWindowBytes;
  bool? hintedUrgent;
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
  void setStreamPosition(
    TorrentHandle handle,
    int byteOffset, {
    int windowBytes = 0,
    bool urgent = false,
  }) {
    hintedByteOffset = byteOffset;
    hintedWindowBytes = windowBytes;
    hintedUrgent = urgent;
  }

  @override
  void setStreamDuration(TorrentHandle handle, int durationMs) {}

  @override
  int? streamReadHead(TorrentHandle handle) => null;

  @override
  String? streamDebugSnapshot(TorrentHandle handle) => null;

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
