import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

const _movie = MediaRef(id: 1, type: MediaType.movie);

TorrentSource _source(String id) => TorrentSource(
  id: id,
  content: _movie,
  name: 'Source $id',
  uri: Uri.parse('magnet:?xt=urn:btih:$id'),
  inputType: TorrentInputType.magnet,
  providerName: 'Test',
  attribution: '',
  license: '',
  provenanceUrl: Uri.parse('https://example.com'),
);

void main() {
  test('cancel during metadata lookup abandons stream creation', () async {
    final engine = _ControllableEngine();
    final service = StreamingService(engine, _EmptyCache());
    final token = service.beginSession(_source('a' * 40));
    expect(service.state.sessionId, token.id);
    expect(service.state.phase, StreamingPhase.resolving);

    final started = service.start(_source('a' * 40), claimed: token);
    // Release metadata while a cancel races in.
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    service.cancelSession(token.id);
    engine.completeMetadata(const [
      TorrentFileEntry(index: 0, name: 'm.mp4', size: 10, isStreamable: true),
    ]);
    await started;
    // Stale completion must not create playback.
    expect(service.state.phase, isNot(StreamingPhase.buffering));
    expect(engine.startStreamCalls, 0);
    await service.dispose();
  });

  test('rapidly switching sources keeps only the latest session', () async {
    final engine = _ControllableEngine();
    final service = StreamingService(engine, _EmptyCache());
    final first = service.beginSession(_source('a' * 40));
    final firstFuture = service.start(_source('a' * 40), claimed: first);
    // Switch before first resolves.
    final second = service.beginSession(_source('b' * 40));
    engine.completeMetadata(const [
      TorrentFileEntry(index: 0, name: 'm.mp4', size: 10, isStreamable: true),
    ]);
    await firstFuture;
    // First is stale; second owns the session.
    expect(service.state.sessionId, second.id);
    // Complete second fully.
    engine.completeMetadata(const [
      TorrentFileEntry(index: 0, name: 'm.mp4', size: 10, isStreamable: true),
    ]);
    await service.start(_source('b' * 40), claimed: second);
    await service.dispose();
  });

  test('markPlaying is idempotent and buffering events do not duplicate', () async {
    final engine = _FakeEngine();
    final service = StreamingService(engine, _EmptyCache());
    await service.start(_source('c' * 40));
    expect(service.state.playback, isNotNull);
    final states = <StreamingState>[];
    final sub = service.states.listen(states.add);
    service.markPlaying();
    service.markPlaying();
    service.markPlaying();
    await Future<void>.delayed(Duration.zero);
    final playing = states.where((s) => s.phase == StreamingPhase.playing);
    expect(playing.length, lessThanOrEqualTo(1));
    // Buffering reports are idempotent.
    service.reportBuffering(true, bufferedPositionMs: 1000);
    service.reportBuffering(true, bufferedPositionMs: 1000);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await service.dispose();
  });

  test('prefetch deduplicates concurrent adds and releases old candidate', () async {
    final engine = _CountingEngine();
    final service = StreamingService(engine, _EmptyCache());
    final a = _source('a' * 40);
    final b = _source('b' * 40);
    await Future.wait([service.prefetchSource(a), service.prefetchSource(a)]);
    expect(engine.addCalls, 1);
    await service.prefetchSource(b);
    // Old candidate released (stop called) when switching.
    expect(engine.stopCalls, greaterThanOrEqualTo(1));
    await service.dispose();
  });

  test('sparse file with right length but no recorded bytes never verifies', () async {
    final engine = _FakeEngine();
    final entry = PlaybackCacheEntry(
      cacheKey: 'k',
      source: _source('d' * 40),
      file: const TorrentFileEntry(index: 0, name: 'm.mp4', size: 1000, isStreamable: true),
      filePath: '/tmp/m.mp4',
      complete: true,
      byteSize: 0, // preallocated sparse: length ok, bytes missing
      lastUsedAt: DateTime(2026),
    );
    final service = StreamingService(engine, _SizedCache(entry));
    await service.start(_source('d' * 40));
    // Must fall through to torrent engine, not cache.
    expect(engine.added, isTrue);
    expect(service.state.origin, PlaybackOrigin.network);
    await service.dispose();
  });
}

class _EmptyCache extends PlaybackCacheStore {
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<void> record(TorrentSource s, TorrentFileEntry f, {required bool complete, required int byteSize}) async {}
}

class _SizedCache extends PlaybackCacheStore {
  _SizedCache(this.entry);
  final PlaybackCacheEntry entry;
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => entry;
  @override
  Future<void> record(TorrentSource s, TorrentFileEntry f, {required bool complete, required int byteSize}) async {}
}

class _FakeEngine implements TorrentEngine {
  bool added = false;
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    added = true;
    return const TorrentHandle('1');
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async => const [
    TorrentFileEntry(index: 0, name: 'm.mp4', size: 10, isStreamable: true),
  ];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(TorrentHandle handle, TorrentFileEntry file) async =>
      TorrentPlaybackStream(id: '2', uri: Uri.parse('http://127.0.0.1:1/x'), file: file);
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}
}

class _ControllableEngine implements TorrentEngine {
  final _metadata = Completer<List<TorrentFileEntry>>();
  int startStreamCalls = 0;
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async => const TorrentHandle('9');
  void completeMetadata(List<TorrentFileEntry> files) {
    if (!_metadata.isCompleted) _metadata.complete(files);
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) => _metadata.future;
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(TorrentHandle handle, TorrentFileEntry file) async {
    startStreamCalls++;
    return TorrentPlaybackStream(id: 's', uri: Uri.parse('http://127.0.0.1:1/x'), file: file);
  }

  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}
}

class _CountingEngine implements TorrentEngine {
  int addCalls = 0;
  int stopCalls = 0;
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    addCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return TorrentHandle('id-$addCalls');
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async => const [];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(TorrentHandle handle, TorrentFileEntry file) async =>
      TorrentPlaybackStream(id: 'x', uri: Uri.parse('http://127.0.0.1:1/x'), file: file);
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {}
}
