import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_forge_player/media_forge_player.dart';
import 'package:peerstream/features/player/player_backend.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/models/watch_progress.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/settings/settings_store.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

TorrentSource _magnetSource(String id) => TorrentSource(
  id: id,
  content: const MediaRef(id: 1, type: MediaType.movie),
  name: 'Source $id',
  uri: Uri.parse('magnet:?xt=urn:btih:$id'),
  inputType: TorrentInputType.magnet,
  providerName: 'Test',
  attribution: '',
  license: '',
  provenanceUrl: Uri.parse('https://example.com'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaForge configuration', () {
    test('native-resolution configuration is requested', () {
      const config = mediaForgeBaseConfiguration;
      expect(
        config.decodeResolution,
        MediaForgeDecodeResolution.native,
      );
      expect(config.isNative, isTrue);
    });

    test('per-source configuration keeps native resolution', () {
      final torrent = buildMediaForgeConfigurationForUri(
        Uri.parse('http://127.0.0.1:8080/stream'),
      );
      final direct = buildMediaForgeConfigurationForUri(
        Uri.parse('https://cdn.example.com/video.mp4'),
      );
      final file = buildMediaForgeConfigurationForUri(
        Uri.file('/tmp/video.mp4'),
      );
      for (final config in [torrent, direct, file]) {
        expect(config.decodeResolution, MediaForgeDecodeResolution.native);
        expect(config.isNative, isTrue);
      }
    });
  });

  group('source-specific network profiles', () {
    test('torrent localhost profile selection', () {
      for (final url in [
        'http://127.0.0.1:8080/stream',
        'http://localhost:8080/stream',
        'http://[::1]:8080/stream',
      ]) {
        final profile = mediaForgeNetworkProfileForUri(Uri.parse(url));
        expect(profile.name, 'torrent_localhost');
        expect(profile.timeout, mediaForgeTorrentTimeout);
        expect(profile.timeout.inSeconds, 60);
        expect(profile.reconnect, isTrue);
        expect(profile.isSeekableRange, isTrue);
      }
      final config = buildMediaForgeConfigurationForUri(
        Uri.parse('http://127.0.0.1:8080/stream'),
      );
      expect(config.networkProfile.name, 'torrent_localhost');
    });

    test('direct HTTP profile selection', () {
      final profile = mediaForgeNetworkProfileForUri(
        Uri.parse('https://cdn.example.com/video.mp4'),
      );
      expect(profile.name, 'direct_http');
      expect(profile.timeout, mediaForgeDirectTimeout);
      expect(profile.timeout.inSeconds, 30);
    });

    test('cached source profile carries no network options', () {
      final profile = mediaForgeNetworkProfileForUri(
        Uri.file('/tmp/video.mp4'),
      );
      expect(profile.name, 'cached_file');
    });

    test('source type classification', () {
      expect(
        classifyMediaForgeSource(Uri.file('/tmp/a.mp4')),
        MediaForgeSourceType.file,
      );
      expect(
        classifyMediaForgeSource(Uri.parse('http://127.0.0.1:1/x')),
        MediaForgeSourceType.torrentLocalhost,
      );
      expect(
        classifyMediaForgeSource(Uri.parse('http://localhost:1/x')),
        MediaForgeSourceType.torrentLocalhost,
      );
      expect(
        classifyMediaForgeSource(Uri.parse('https://cdn.example.com/v.mp4')),
        MediaForgeSourceType.directHttp,
      );
    });
  });

  group('buildMediaForgeMedia honors source type', () {
    test('torrent localhost keeps headers with streaming timeout', () {
      final media = buildMediaForgeMedia(
        uri: Uri.parse('http://127.0.0.1:8080/stream'),
        headers: const {'Authorization': 'Bearer x'},
        userAgent: 'PeerStream/1.0',
      );
      expect(media, isA<MediaForgeNetwork>());
      final network = media as MediaForgeNetwork;
      expect(network.url, 'http://127.0.0.1:8080/stream');
      expect(network.headers, {'Authorization': 'Bearer x'});
      expect(network.userAgent, 'PeerStream/1.0');
      expect(network.timeout, mediaForgeTorrentTimeout);
      expect(network.reconnect, isTrue);
      expect(network.isLoopback, isTrue);
    });

    test('direct HTTP preserves headers, user agent, and reconnect', () {
      final media = buildMediaForgeMedia(
        uri: Uri.parse('https://cdn.example.com/video.mp4'),
        headers: const {'Referer': 'https://example.com'},
        userAgent: 'PeerStream/1.0',
      );
      expect(media, isA<MediaForgeNetwork>());
      final network = media as MediaForgeNetwork;
      expect(network.headers, {'Referer': 'https://example.com'});
      expect(network.userAgent, 'PeerStream/1.0');
      expect(network.timeout, mediaForgeDirectTimeout);
      expect(network.reconnect, isTrue);
      expect(network.isLoopback, isFalse);
    });

    test('cached source opens as file', () {
      final media = buildMediaForgeMedia(uri: Uri.file('/tmp/video.mp4'));
      expect(media, isA<MediaForgeFile>());
    });
  });

  group('first-frame playback state', () {
    test('non-zero position without first frame is not ready', () {
      expect(
        isMediaForgeVisuallyReady(
          isInitialized: true,
          firstFramePresented: false,
          hasError: false,
        ),
        isFalse,
      );
      expect(
        resolveMediaForgeStage(
          hasError: false,
          isCompleted: false,
          isInitialized: true,
          firstFramePresented: false,
          isPlaying: true,
          isBuffering: false,
          hasPendingSeek: false,
        ),
        MediaForgePlaybackStage.buffering,
      );
    });

    test('first frame presented controls ready state', () {
      expect(
        isMediaForgeVisuallyReady(
          isInitialized: true,
          firstFramePresented: true,
          hasError: false,
        ),
        isTrue,
      );
      expect(
        resolveMediaForgeStage(
          hasError: false,
          isCompleted: false,
          isInitialized: true,
          firstFramePresented: true,
          isPlaying: true,
          isBuffering: false,
          hasPendingSeek: false,
        ),
        MediaForgePlaybackStage.playing,
      );
    });

    test('stage distinguishes seeking, rebuffering, ended, error', () {
      MediaForgePlaybackStage stage({
        bool error = false,
        bool completed = false,
        bool initialized = true,
        bool first = true,
        bool playing = true,
        bool buffering = false,
        bool pendingSeek = false,
      }) => resolveMediaForgeStage(
        hasError: error,
        isCompleted: completed,
        isInitialized: initialized,
        firstFramePresented: first,
        isPlaying: playing,
        isBuffering: buffering,
        hasPendingSeek: pendingSeek,
      );

      expect(stage(pendingSeek: true), MediaForgePlaybackStage.seeking);
      expect(
        stage(buffering: true),
        MediaForgePlaybackStage.rebuffering,
      );
      expect(stage(completed: true), MediaForgePlaybackStage.ended);
      expect(stage(error: true), MediaForgePlaybackStage.error);
      expect(
        stage(initialized: false, first: false, playing: false),
        MediaForgePlaybackStage.opening,
      );
      expect(
        stage(playing: false),
        MediaForgePlaybackStage.firstFramePresented,
      );
    });
  });

  group('seek generations', () {
    test('stale completions are ignored', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(1);
      coordinator.onSeekStarted(2);
      expect(coordinator.hasPendingSeek, isTrue);
      // Earlier completion must not overwrite the newer seek.
      expect(coordinator.shouldApplySettled(1), isFalse);
      expect(coordinator.hasPendingSeek, isTrue);
      expect(coordinator.shouldApplySettled(2), isTrue);
      coordinator.onSeekSettled(2);
      expect(coordinator.hasPendingSeek, isFalse);
    });

    test('duplicate settle does not reapply', () {
      final coordinator = MediaForgeSeekCoordinator();
      coordinator.onSeekStarted(4);
      coordinator.onSeekSettled(4);
      expect(coordinator.shouldApplySettled(4), isFalse);
    });
  });

  group('StreamingService MediaForge hooks', () {
    test('seek-start/seek-settled propagate with generations', () async {
      final service = StreamingService(
        _FakeEngine(),
        _EmptyCache(),
      );
      await service.start(_magnetSource('e' * 40));
      expect(service.state.playback, isNotNull);

      service.reportSeekStarted(generation: 7);
      expect(service.state.phase, StreamingPhase.seeking);
      expect(service.activeSeekGeneration, 7);

      // Stale settle for an older generation is dropped.
      service.reportSeekSettled(generation: 6);
      expect(service.state.phase, StreamingPhase.seeking);
      expect(service.lastSettledSeekGeneration, isNull);

      service.reportSeekSettled(generation: 7);
      expect(service.state.phase, StreamingPhase.playing);
      expect(service.lastSettledSeekGeneration, 7);
      await service.dispose();
    });

    test('active playback position is recorded without emitting', () async {
      final service = StreamingService(
        _FakeEngine(),
        _EmptyCache(),
      );
      await service.start(_magnetSource('f' * 40));
      var emissions = 0;
      final sub = service.states.listen((_) => emissions++);
      service.reportPlaybackPosition(12345);
      service.reportPlaybackPosition(12400);
      await Future<void>.delayed(Duration.zero);
      expect(service.lastPlayerPositionMs, 12400);
      expect(service.lastPlayerPositionAt, isNotNull);
      expect(emissions, 0);
      await sub.cancel();
      await service.dispose();
    });

    test('ungenerated seek reports keep legacy behavior', () async {
      final service = StreamingService(
        _FakeEngine(),
        _EmptyCache(),
      );
      await service.start(_magnetSource('g' * 40));
      service.reportSeekStarted();
      expect(service.state.phase, StreamingPhase.seeking);
      service.reportSeekSettled();
      expect(service.state.phase, StreamingPhase.playing);
      await service.dispose();
    });
  });

  group('lifecycle forwarding', () {
    test('background suspends, foreground resumes', () {
      expect(
        mediaForgeLifecycleAction(AppLifecycleState.paused),
        MediaForgeLifecycleAction.suspend,
      );
      expect(
        mediaForgeLifecycleAction(AppLifecycleState.inactive),
        MediaForgeLifecycleAction.suspend,
      );
      expect(
        mediaForgeLifecycleAction(AppLifecycleState.detached),
        MediaForgeLifecycleAction.suspend,
      );
      expect(
        mediaForgeLifecycleAction(AppLifecycleState.hidden),
        MediaForgeLifecycleAction.suspend,
      );
      expect(
        mediaForgeLifecycleAction(AppLifecycleState.resumed),
        MediaForgeLifecycleAction.resume,
      );
    });
  });

  group('deterministic teardown', () {
    test('player releases before the torrent session stops', () async {
      final order = <String>[];
      await runMediaForgeTeardown(
        releasePlayer: () async {
          order.add('release-player');
        },
        stopTorrent: () async {
          order.add('stop-torrent');
        },
      );
      expect(order, ['release-player', 'stop-torrent']);
    });

    test('torrent still stops when player release throws', () async {
      final order = <String>[];
      await expectLater(
        runMediaForgeTeardown(
          releasePlayer: () async {
            order.add('release-player');
            throw StateError('already released');
          },
          stopTorrent: () async {
            order.add('stop-torrent');
          },
        ),
        throwsStateError,
      );
      expect(order, ['release-player', 'stop-torrent']);
    });
  });

  group('dispose-safe persist entry', () {
    WatchEntry? buildEntry({int positionMs = 61000, int durationMs = 3600000}) =>
        buildWatchPersistEntry(
          positionMs: positionMs,
          durationMs: durationMs,
          key: 'movie-1',
          media: const MediaRef(id: 1, type: MediaType.movie),
          title: 'Cached Title',
          posterPath: '/p.jpg',
          backdropPath: '/b.jpg',
          season: null,
          episode: null,
          sourceId: 's1',
          providerName: 'Test',
          sourceUri: 'http://127.0.0.1:1/x',
          inputType: 'magnet',
        );

    test('zero position records nothing (safe from dispose)', () {
      expect(buildEntry(positionMs: 0), isNull);
      expect(buildEntry(positionMs: -5), isNull);
    });

    test('normal progress builds a resumable entry', () {
      final entry = buildEntry();
      expect(entry, isNotNull);
      expect(entry!.positionMs, 61000);
      expect(entry.title, 'Cached Title');
      expect(entry.posterPath, '/p.jpg');
      expect(entry.isResumable, isTrue);
    });

    test('finished and trivial entries are detectable without providers', () {
      // Finished → caller removes the key.
      expect(buildEntry(positionMs: 3599000)!.isFinished, isTrue);
      // Trivial → caller skips the save.
      expect(buildEntry(positionMs: 1000)!.isTrivial, isTrue);
    });
  });

  group('fallback contract', () {    test('failure fallback preserves latest valid position', () {
      expect(
        resolveFallbackResumeMs(
          controllerPositionMs: 90123,
          explicitStartMs: 1000,
          widgetResumeMs: 500,
        ),
        90123,
      );
    });

    test('fallback preserves the saved MediaForge preference', () async {
      SharedPreferences.setMockInitialValues({});
      await writeAppSettings(
        const AppSettings().copyWith(useMediaForgePlayer: true),
      );
      // Simulate a MediaForge failure: resolve the fallback position.
      // This must never write settings.
      resolveFallbackResumeMs(controllerPositionMs: 4242);
      expect((await readAppSettings()).useMediaForgePlayer, isTrue);
    });
  });

  group('backend freezing', () {
    test('default player remains the default', () {
      expect(
        resolveBackend(const AppSettings(useMediaForgePlayer: false)),
        PlayerBackend.defaultPlayer,
      );
    });

    test('no backend hot-swap during an active session', () {
      final frozen = freezeBackendChoice(
        null,
        resolveBackend(const AppSettings(useMediaForgePlayer: true)),
      );
      expect(frozen, PlayerBackend.mediaForge);
      // Toggling the setting mid-session must not swap the active backend.
      final stillFrozen = freezeBackendChoice(
        frozen,
        resolveBackend(const AppSettings(useMediaForgePlayer: false)),
      );
      expect(stillFrozen, PlayerBackend.mediaForge);
    });
  });

  group('benchmark payload', () {
    test('keeps torrent delay separate from decoder latency', () {
      final payload = buildMediaForgeBenchmarkPayload(
        requested: PlayerBackend.mediaForge,
        active: PlayerBackend.mediaForge,
        sourceType: MediaForgeSourceType.torrentLocalhost,
        tapToFirstFrameMs: 12000,
        firstFrameLatencyMs: 850,
        lastSeekLatencyMs: 210,
        lastSeekGeneration: 3,
        presentedFps: 59.5,
        decodedFps: 60.0,
        droppedFrames: 2,
        avDriftMs: 12,
        activeDecoder: 'hevc_software',
        renderingPath: 'software_rgba_upload',
        rebufferEvents: 1,
        stallEvents: 0,
        positionMs: 61000,
      );
      expect(payload['requestedBackend'], 'MediaForge');
      expect(payload['activeBackend'], 'MediaForge');
      expect(payload['sourceType'], 'torrent_localhost');
      expect(payload['tapToFirstFrameMs'], 12000);
      expect(payload['firstFrameLatencyMs'], 850);
      expect(payload['lastSeekLatencyMs'], 210);
      expect(payload['lastSeekGeneration'], 3);
      expect(payload['presentedFps'], 59.5);
      expect(payload['droppedFrames'], 2);
      expect(payload['avDriftMs'], 12);
      expect(payload['activeDecoder'], 'hevc_software');
      expect(payload['renderingPath'], 'software_rgba_upload');
      expect(payload['rebufferEvents'], 1);
      // Never throws when logging.
      expect(() => logMediaForgeBenchmark(payload), returnsNormally);
    });
  });
}

class _EmptyCache extends PlaybackCacheStore {
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<void> record(
    TorrentSource s,
    TorrentFileEntry f, {
    required bool complete,
    required int byteSize,
  }) async {}
}

class _FakeEngine implements TorrentEngine {
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async =>
      const TorrentHandle('1');
  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async =>
      const [
        TorrentFileEntry(index: 0, name: 'm.mp4', size: 10, isStreamable: true),
      ];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => TorrentPlaybackStream(
    id: '2',
    uri: Uri.parse('http://127.0.0.1:1/x'),
    file: file,
  );
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}
}
