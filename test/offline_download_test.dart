import 'dart:async';

import 'empty_playback_cache.dart';

import 'package:peerstream/services/experience/playback_experience.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/playback/torrent_cache_identity.dart';
import 'package:peerstream/services/streaming/offline_download.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

final source = TorrentSource(
  id: 'offline-test',
  content: const MediaRef(id: 1, type: MediaType.movie),
  name: 'Original fixture',
  uri: Uri.parse(
    'magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ),
  inputType: TorrentInputType.magnet,
  providerName: 'Test',
  attribution: 'Original',
  license: 'CC0',
  provenanceUrl: Uri.parse('about:blank'),
);
void main() {
  test(
    'metadata failure still stops a paused transfer and reports failure',
    () async {
      final engine = _Engine();
      final cache = _Cache();
      final job = OfflineDownload(
        engine,
        cache,
        journal: PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
      await job.save(source, playbackActive: false);
      cache.failRecord = true;
      await expectLater(job.pause(), throwsStateError);
      expect(engine.stops, 1);
      expect(job.state.value?.phase, OfflinePhase.error);
      cache.failRecord = false;
      await job.resume(playbackActive: false);
      expect(engine.downloads, 2);
      await job.dispose();
    },
  );
  test(
    'a failed native stop retains its handle until a successful retry',
    () async {
      final engine = _Engine();
      final job = OfflineDownload(
        engine,
        _Cache(),
        journal: PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
      await job.save(source, playbackActive: false);
      engine.failStop = true;
      await expectLater(job.pause(), throwsStateError);
      await expectLater(job.resume(playbackActive: false), throwsStateError);
      expect(engine.downloads, 1);
      expect(engine.adds, 1);
      engine.failStop = false;
      await job.resume(playbackActive: false);
      expect(engine.adds, 2);
      expect(engine.stops, 3);
      await job.dispose();
    },
  );
  test(
    'a user-paused download remains paused across playback and stop',
    () async {
      final engine = _Engine();
      final journal = PlaybackExperience(
        read: () async => {},
        write: (_) async {},
      );
      final service = StreamingService.withExperience(
        engine,
        _Cache(),
        journal,
      );
      await service.saveOffline(source);
      await service.offline.pause();
      final direct = TorrentSource(
        id: 'direct',
        content: source.content,
        name: 'Direct fixture',
        uri: Uri.parse('https://example.com/fixture.mp4'),
        inputType: TorrentInputType.directUrl,
        providerName: source.providerName,
        attribution: source.attribution,
        license: source.license,
        provenanceUrl: source.provenanceUrl,
      );
      await service.start(direct);
      await service.stop();
      await Future<void>.delayed(Duration.zero);
      expect(service.offline.userPaused, isTrue);
      expect(engine.downloads, 1);
      await service.dispose();
    },
  );
  test('a request waiting for playback persists and restores paused', () async {
    Map<String, dynamic> saved = {};
    final journal = PlaybackExperience(
      read: () async => {},
      write: (v) async {
        saved = v;
      },
    );
    final first = OfflineDownload(_Engine(), _Cache(), journal: journal);
    await first.save(source, playbackActive: true);
    expect(saved['offlineIntent'], isNotNull);
    await first.dispose();
    final restored = OfflineDownload(
      _Engine(),
      _Cache(),
      journal: PlaybackExperience(read: () async => saved, write: (_) async {}),
    );
    await restored.restoreIntent();
    expect(restored.state.value?.source.id, source.id);
    expect(restored.state.value?.phase, OfflinePhase.paused);
    expect(restored.userPaused, isTrue);
    await restored.dispose();
  });
  test('offline save stays paused during playback and native verification gates completion', () async {
    final engine = _Engine();
    final cache = _Cache();
    final job = OfflineDownload(
      engine,
      cache,
      journal: PlaybackExperience(read: () async => {}, write: (_) async {}),
    );
    await job.save(source, playbackActive: true);
    expect(job.state.value?.phase, OfflinePhase.paused);
    expect(engine.downloads, 0);
    await job.resume(playbackActive: false);
    expect(job.state.value?.phase, OfflinePhase.downloading);
    expect(cache.row?.pinned, isTrue);
    expect(cache.row?.complete, isFalse);
    engine.verified = true;
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(job.state.value?.phase, OfflinePhase.complete);
    expect(cache.row?.complete, isTrue);
    expect(cache.row?.pinned, isTrue);
    await job.dispose();
  });
  test(
    'budget refusal releases the handle and does not start a download',
    () async {
      final engine = _Engine();
      final cache = _Cache()..budget = 1;
      final job = OfflineDownload(
        engine,
        cache,
        journal: PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
      await expectLater(
        job.save(source, playbackActive: false),
        throwsStateError,
      );
      expect(engine.downloads, 0);
      expect(engine.stops, 1);
      expect(job.state.value?.phase, OfflinePhase.error);
      await job.dispose();
    },
  );
  test(
    'cancel interrupts metadata preparation and retains cached data',
    () async {
      final engine = _Engine()
        ..pendingFiles = Completer<List<TorrentFileEntry>>();
      final job = OfflineDownload(
        engine,
        _Cache(),
        journal: PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
      final starting = job.save(source, playbackActive: false);
      await engine.added.future;
      await Future<void>.delayed(Duration.zero);
      await job.cancel().timeout(const Duration(seconds: 1));
      await starting;
      expect(job.state.value, isNull);
      expect(engine.downloads, 0);
      expect(engine.stops, 1);
      engine.pendingFiles!.complete([_file]);
      await job.dispose();
    },
  );
}

const _file = TorrentFileEntry(
  index: 0,
  name: 'fixture.mp4',
  size: 1024,
  isStreamable: true,
);

class _Engine
    implements
        TorrentEngine,
        OfflineDownloadController,
        FileCompletenessChecker {
  int downloads = 0;
  int stops = 0;
  int adds = 0;
  bool failStop = false;
  bool verified = false;
  final added = Completer<void>();
  Completer<List<TorrentFileEntry>>? pendingFiles;
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    adds++;
    if (!added.isCompleted) added.complete();
    return const TorrentHandle('1');
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async =>
      pendingFiles == null ? [_file] : await pendingFiles!.future;
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<void> downloadFile(TorrentHandle handle, TorrentFileEntry file) async {
    downloads++;
  }

  @override
  Future<bool> isFileComplete(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => verified;
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    expect(deleteFiles, isFalse);
    stops++;
    if (failStop) throw StateError('Native stop failed');
  }

  @override
  Future<void> dispose() async {}
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) => throw UnimplementedError('Not used by offline coordinator');
}

class _Cache extends EmptyPlaybackCache {
  bool failRecord = false;
  int budget = 2048;
  PlaybackCacheEntry? row;
  @override
  Future<PlaybackPreferences> preferences() async =>
      PlaybackPreferences(maxCacheBytes: budget);
  @override
  Future<List<PlaybackCacheEntry>> entries() async => [?row];
  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) async {
    if (failRecord) throw StateError('Storage unavailable');
    row = PlaybackCacheEntry(
      cacheKey: torrentCacheKey(source),
      source: source,
      file: file,
      filePath: 'fixture',
      complete: complete,
      byteSize: byteSize,
      lastUsedAt: DateTime.now(),
      pinned: row?.pinned ?? false,
    );
  }

  @override
  Future<void> setPinned(String key, bool pinned) async {
    if (row != null) row = row!.copyWith(pinned: pinned);
  }
}
