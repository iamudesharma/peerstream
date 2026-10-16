import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:peerstream/services/local_service/service_client.dart';
import 'package:peerstream/services/local_service/service_torrent_engine.dart';
import 'package:peerstream/services/local_service/service_cache.dart';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:peerstream/services/storage/app_storage.dart';
import 'package:peerstream/services/storage/app_storage_native.dart'
    as fixture_storage;
import 'package:peerstream/services/experience/playback_experience.dart';
import 'package:peerstream/services/experience/playback_queue.dart';
import 'package:peerstream/core/theme.dart';
import 'package:peerstream/features/player/default_player_screen.dart';
import 'package:peerstream/features/player/player_track_selectors.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/media_details.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/models/watch_progress.dart';
import 'package:peerstream/providers/app_providers.dart';
import 'package:peerstream/providers/player_providers.dart';
import 'package:peerstream/providers/settings_providers.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/playback/torrent_cache_identity.dart';
import 'package:peerstream/services/settings/settings_store.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/bundled_torrent_api.dart';
import 'package:peerstream/services/torrent/native_torrent_engine.dart';
import 'package:peerstream/services/torrent/source_policy.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

const _fixturePath = String.fromEnvironment('PEERSTREAM_PLAYER_FIXTURE');
const _runService = bool.fromEnvironment('PEERSTREAM_SERVICE_TEST');
const _resourceCycles = int.fromEnvironment(
  'PEERSTREAM_RESOURCE_CYCLES',
  defaultValue: 0,
);
const _soakMinutes = int.fromEnvironment(
  'PEERSTREAM_SOAK_MINUTES',
  defaultValue: 0,
);
const _runColdTorrent = bool.fromEnvironment('PEERSTREAM_COLD_TORRENT');
const _resourceOnly = bool.fromEnvironment('PEERSTREAM_RESOURCE_ONLY');
const _torrentResourceCycles = bool.fromEnvironment(
  'PEERSTREAM_TORRENT_RESOURCE_CYCLES',
);
const _resourceBackend = String.fromEnvironment(
  'PEERSTREAM_RESOURCE_BACKEND',
  defaultValue: 'native',
);
TestGesture? _controlMouse;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // Establish native accessibility before test baselines are captured. An AX
  // client attaching mid-test otherwise creates an unowned platform handle.
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  MediaKit.ensureInitialized();

  testWidgets('default player starts and switches native audio and subtitles', (
    tester,
  ) async {
    expect(_fixturePath, isNotEmpty, reason: 'Generate the fixture first.');
    await tester.runAsync(appStorage.initialize);
    final file = File(_fixturePath);
    expect(await tester.runAsync(file.exists), isTrue);
    const media = MediaRef(id: -90900, type: MediaType.movie);
    final source = TorrentSource(
      id: 'generated-player-fixture',
      content: media,
      name: 'Player verification',
      uri: file.uri,
      inputType: TorrentInputType.directUrl,
      providerName: 'Generated fixture',
      attribution: 'Original generated test media',
      license: 'CC0',
      provenanceUrl: Uri.parse('about:blank'),
    );
    final session = await _mount(tester, source, _DirectOnlyEngine());
    try {
      await _waitUntil(tester, () => session.visiblePlaybackMs != null);
      binding.reportData = {'direct': session.metrics};
      expect(session.visiblePlaybackMs!, lessThanOrEqualTo(5000));
      expect(session.sourceLookups, 0);
      await _waitUntil(
        tester,
        () =>
            realAudioTracks(session.player.state.tracks).length == 2 &&
            realSubtitleTracks(session.player.state.tracks).length == 2,
      );

      debugPrint('[PlayerVerification] embedded tracks discovered');
      await _showControls(tester);
      await tester.tap(find.byType(MaterialDesktopFullscreenButton).first);
      await _pump(tester, const Duration(milliseconds: 400));
      debugPrint('[PlayerVerification] fullscreen controls mounted');
      final audio = realAudioTracks(session.player.state.tracks);
      expect(audio.map((track) => track.codec), containsAll(['mp3', 'ac3']));
      for (final track in [audio.last, audio.first]) {
        await _select(
          tester,
          'Audio track',
          track.id,
          track.title,
          track.language,
        );
        await _expectNativeProperty(tester, session.player, 'aid', track.id);
        debugPrint('[PlayerVerification] native aid=${track.id}');
        await _showControls(tester);
        await tester.tap(find.byTooltip('Audio track').last);
        await _pump(tester, const Duration(milliseconds: 400));
        final row = find.widgetWithText(
          ListTile,
          controlsTrackLabel(track.id, track.title, track.language),
        );
        expect(
          find.descendant(of: row, matching: find.byIcon(Icons.check)),
          findsOneWidget,
        );
        await tester.tap(row);
        await _pump(tester, const Duration(milliseconds: 400));
      }

      final subtitles = realSubtitleTracks(session.player.state.tracks);
      for (final track in [subtitles.last, subtitles.first]) {
        await _select(
          tester,
          'Subtitle track',
          track.id,
          track.title,
          track.language,
        );
        await _expectNativeProperty(tester, session.player, 'sid', track.id);
        await tester.runAsync(session.player.play);
        debugPrint('[PlayerVerification] native sid=${track.id}');
        final text = track.language == 'hin'
            ? 'Hindi subtitle fixture'
            : 'English subtitle fixture';
        await _waitUntil(tester, () => find.text(text).evaluate().isNotEmpty);
      }
      await _select(tester, 'Subtitle track', 'no', null, null);
      await _expectNativeProperty(tester, session.player, 'sid', 'no');
      await _waitUntil(
        tester,
        () => find.text('English subtitle fixture').evaluate().isEmpty,
      );
      await _showControls(tester);
      await tester.tap(find.byTooltip('Player settings').last);
      await _pump(tester, const Duration(milliseconds: 400));
      _expectMenuBounds(tester);
      await tester.tap(find.text('Playback speed'));
      await _pump(tester, const Duration(milliseconds: 400));
      final speedChoice = find.widgetWithText(ListTile, '1.5×');
      await tester.ensureVisible(speedChoice);
      await tester.tap(speedChoice);
      await _pump(tester, const Duration(milliseconds: 400));
      final speed = await tester.runAsync(
        () => (session.player.platform as NativePlayer).getProperty('speed'),
      );
      expect(double.tryParse(speed!), 1.5);
      await _showControls(tester);
      await tester.tap(find.byTooltip('Player settings').last);
      await _pump(tester, const Duration(milliseconds: 200));
      await tester.ensureVisible(find.text('Synchronization'));
      await tester.tap(find.text('Synchronization'));
      await _pump(tester, const Duration(milliseconds: 200));
      await tester.ensureVisible(find.byTooltip('Audio later'));
      await tester.tap(find.byTooltip('Audio later'));
      await _pump(tester, const Duration(milliseconds: 100));
      final nativePlayer = session.player.platform as NativePlayer;
      final delay = await tester.runAsync(
        () => nativePlayer.getProperty('audio-delay'),
      );
      expect(double.parse(delay!), closeTo(0.05, 0.001));
      await tester.ensureVisible(find.byTooltip('Subtitle later'));
      await tester.tap(find.byTooltip('Subtitle later'));
      await _pump(tester, const Duration(milliseconds: 100));
      final subtitleDelay = await tester.runAsync(
        () => nativePlayer.getProperty('sub-delay'),
      );
      expect(double.parse(subtitleDelay!), closeTo(0.1, 0.001));
      binding.reportData!['nativeTimingVerified'] = true;
      binding.reportData!['nativeTracksVerified'] = true;
    } catch (error, stack) {
      debugPrint('[PlayerVerification] failure: $error\n$stack');
      rethrow;
    } finally {
      await session.close(tester);
    }
  }, skip: _resourceOnly);

  testWidgets('default player repeats sessions with bounded process footprint', (
    tester,
  ) async {
    await tester.runAsync(appStorage.initialize);
    final cache = await _newCache(tester);
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    final resourceClient = _resourceBackend == 'service'
        ? LocalServiceClient(
            executable: '$contents/Helpers/peerstream-service',
            library:
                '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
            root: '${cache.root.path}/service',
          )
        : null;
    if (resourceClient != null) {
      cache.delegate = ServicePlaybackCacheStore(resourceClient);
    }
    final TorrentEngine engine = resourceClient != null
        ? ServiceTorrentEngine(resourceClient)
        : NativeTorrentEngine(
            cache: cache,
            sessionCacheDirectory: () async => cache.root.path,
          );
    final diagnosticsProvider = engine as EngineDiagnosticsProvider;
    await tester.runAsync(engine.initialize);
    final service = StreamingService.withExperience(
      engine,
      cache,
      PlaybackExperience(read: () async => {}, write: (_) async {}),
    );
    final player = Player();
    final video = VideoController(player);
    final source = TorrentSource(
      id: 'resource-fixture',
      content: const MediaRef(id: -90901, type: MediaType.movie),
      name: 'Resource verification',
      uri: File(_fixturePath).uri,
      inputType: TorrentInputType.directUrl,
      providerName: 'Original fixture',
      attribution: 'Generated',
      license: 'CC0',
      provenanceUrl: Uri.parse('about:blank'),
    );
    final footprints = <int>[];
    _Session? active;
    _MatrixVideoSeed? resourceSeed;
    try {
      for (var cycle = 0; cycle < _resourceCycles; cycle++) {
        if (_torrentResourceCycles) {
          resourceSeed = await _MatrixVideoSeed.start(tester, _fixturePath);
        }
        active = await _mount(
          tester,
          resourceSeed?.source('cold') ?? source,
          engine,
          cache: cache,
          sharedPlayer: player,
          sharedVideo: video,
          sharedService: service,
        );
        await _waitUntil(tester, () => active!.playingMs != null);
        for (final target in [
          const Duration(seconds: 40),
          const Duration(seconds: 1),
        ]) {
          await tester.runAsync(() => player.seek(target));
          await _waitUntil(
            tester,
            () =>
                (player.state.position - target).abs() <
                const Duration(seconds: 2),
          );
        }
        await _pump(tester, const Duration(milliseconds: 500));
        final diagnostics = await tester.runAsync(
          diagnosticsProvider.engineDiagnostics,
        );
        final appFootprint = (await tester.runAsync(
          () async => _readAppFootprint(contents),
        ))!;
        final combined = _resourceBackend == 'service'
            ? appFootprint + diagnostics!.processMemoryBytes!
            : appFootprint;
        footprints.add(combined);
        debugPrint(
          '[ResourceVerification] ${jsonEncode({'cycle': cycle + 1, 'backend': _resourceBackend, 'torrentRangePlayback': _torrentResourceCycles, 'physicalFootprintBytes': footprints.last})}',
        );
        await active.close(tester, disposeService: false, deleteCache: false);
        active = null;
        await tester.runAsync(() async => resourceSeed?.close());
        resourceSeed = null;
      }
      if (footprints.length >= 10) {
        final warm = footprints.sublist(3, 6).reduce((a, b) => a + b) / 3;
        final settled =
            footprints.sublist(footprints.length - 3).reduce((a, b) => a + b) /
            3;
        binding.reportData ??= {};
        binding.reportData!['resourceCycles'] = {
          'cycles': footprints.length,
          'backend': _resourceBackend,
          'torrentRangePlayback': _torrentResourceCycles,
          'positionConfirmedSeeks': footprints.length * 2,
          'fixtureSeedPayloadBytes':
              _MatrixVideoSeed._sharedFixtureBytes?.length ?? 0,
          'memoryScope': 'Active steady playback physical footprint; app plus helper when service-backed.',
          'warmedFootprintBytes': warm,
          'settledFootprintBytes': settled,
          'growthRatio': settled / warm,
        };
        debugPrint(
          '[ResourceVerification] ${jsonEncode({'cyclesSummary': binding.reportData!['resourceCycles']})}',
        );
        expect(settled, lessThanOrEqualTo(warm * 1.1));
      }
      if (_soakMinutes > 0) {
        active = await _mount(
          tester,
          source,
          engine,
          cache: cache,
          sharedPlayer: player,
          sharedVideo: video,
          sharedService: service,
        );
        await _waitUntil(tester, () => active!.playingMs != null);
        await tester.runAsync(
          () => player.setPlaylistMode(PlaylistMode.single),
        );
        final soakStarted = DateTime.now();
        final deadline = soakStarted.add(Duration(minutes: _soakMinutes));
        var ticks = 0;
        var trackChanges = 0;
        Duration? previousPosition;
        while (DateTime.now().isBefore(deadline)) {
          await _pump(tester, const Duration(seconds: 1));
          ticks++;
          if (ticks % 60 == 0) {
            final d = await tester.runAsync(
              diagnosticsProvider.engineDiagnostics,
            );
            debugPrint(
              '[ResourceVerification] ${jsonEncode({'soakSeconds': ticks, 'physicalFootprintBytes': d!.processMemoryBytes})}',
            );
          }
          if (ticks % 30 == 0) {
            await _waitUntil(tester, () => player.state.playing);
            final position = player.state.position;
            if (previousPosition != null) {
              expect(
                (position - previousPosition).abs(),
                greaterThan(const Duration(milliseconds: 100)),
                reason: 'Video position must advance during the soak, including loop wraps.',
              );
            }
            previousPosition = position;
            final tracks = realAudioTracks(player.state.tracks);
            if (tracks.length > 1) {
              final track = tracks[(ticks ~/ 30) % tracks.length];
              await tester.runAsync(() => player.setAudioTrack(track));
              await _expectNativeProperty(tester, player, 'aid', track.id);
              trackChanges++;
            }
            final subtitles = realSubtitleTracks(player.state.tracks);
            if (subtitles.length > 1) {
              final track = subtitles[(ticks ~/ 30) % subtitles.length];
              await tester.runAsync(() => player.setSubtitleTrack(track));
              await _expectNativeProperty(tester, player, 'sid', track.id);
              trackChanges++;
            }
          }
        }
        await _waitUntil(tester, () => player.state.playing);
        binding.reportData ??= {};
        binding.reportData!['soak'] = {
          'elapsedSeconds': DateTime.now().difference(soakStarted).inSeconds,
          'nativeTrackChanges': trackChanges,
          'playingAtEnd': player.state.playing,
        };
        debugPrint(
          '[ResourceVerification] ${jsonEncode({'soakSummary': binding.reportData!['soak']})}',
        );
      }
    } catch (error, stack) {
      debugPrint('[ResourceVerification] failure: $error\n$stack');
      rethrow;
    } finally {
      if (active != null) {
        await active.close(tester, disposeService: false, deleteCache: false);
      }
      await tester.runAsync(() async => resourceSeed?.close());
      debugPrint('[ResourceVerification] disposing shared service');
      await tester.runAsync(service.dispose);
      debugPrint('[ResourceVerification] deleting isolated cache');
      await tester.runAsync(() async {
        if (await cache.root.exists()) await cache.root.delete(recursive: true);
      });
      debugPrint('[ResourceVerification] resources closed');
    }
  }, skip: _resourceCycles == 0);

  testWidgets('Rust service presents video through the default player', (
    tester,
  ) async {
    await tester.runAsync(appStorage.initialize);
    final cache = await _newCache(tester);
    final bytes = (await tester.runAsync(
      () => File(_fixturePath).readAsBytes(),
    ))!;
    const piece = 256 * 1024;
    final hashes = <int>[];
    for (var offset = 0; offset < bytes.length; offset += piece) {
      hashes.addAll(
        sha1
            .convert(
              bytes.sublist(offset, (offset + piece).clamp(0, bytes.length)),
            )
            .bytes,
      );
    }
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    final torrent = _bencode({
      'info': {
        'name': 'video.mkv',
        'length': bytes.length,
        'piece length': piece,
        'pieces': Uint8List.fromList(hashes),
      },
      'url-list': ['http://127.0.0.1:${server.port}/video.mkv'],
    });
    final serving = server.listen((request) async {
      try {
        if (request.uri.path == '/video.torrent') {
          request.response.add(torrent);
        } else {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          var start = 0;
          var end = bytes.length - 1;
          if (range != null) {
            final parts = range.substring(6).split('-');
            start = int.parse(parts[0]);
            if (parts[1].isNotEmpty) end = int.parse(parts[1]);
            request.response.statusCode = 206;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          request.response.add(bytes.sublist(start, end + 1));
        }
        await request.response.close();
      } catch (_) {
        request.response.close();
      }
    });
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    final client = LocalServiceClient(
      executable: '$contents/Helpers/peerstream-service',
      library:
          '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
      root: '${cache.root.path}/service',
    );
    final engine = ServiceTorrentEngine(client);
    final source = TorrentSource(
      id: 'service-video-fixture',
      content: const MediaRef(id: -90903, type: MediaType.movie),
      name: 'Original service fixture',
      uri: Uri.parse('http://127.0.0.1:${server.port}/video.torrent'),
      inputType: TorrentInputType.torrentUrl,
      providerName: 'Original generated fixture',
      attribution: 'Original fixture',
      license: 'CC0',
      provenanceUrl: Uri.parse('about:blank'),
    );
    _Session? session;
    try {
      session = await _mount(tester, source, engine, cache: cache);
      await _waitUntil(
        tester,
        () => session!.visiblePlaybackMs != null,
        timeout: const Duration(seconds: 30),
      );
      expect(session.sourceLookups, 0);
      expect(session.service.state.playback!.uri.host, '127.0.0.1');
      final metrics = await tester.runAsync(engine.engineDiagnostics);
      expect(metrics!.bridgeVersion, nativeBridgeVersion);
      debugPrint(
        '[ServiceVerification] ${jsonEncode({...session.metrics, 'servicePhysicalFootprintBytes': metrics.processMemoryBytes, 'bridgeVersion': metrics.bridgeVersion})}',
      );
    } catch (error, stack) {
      debugPrint('[ServiceVerification] failure $error\n$stack');
      rethrow;
    } finally {
      if (session != null) {
        await session.close(tester);
      } else {
        await tester.runAsync(client.close);
      }
      await tester.runAsync(() async {
        await serving.cancel();
        await server.close(force: true);
      });
    }
  }, skip: !_runService);

  testWidgets('cold legal torrent reaches its first frame within ten seconds', (
    tester,
  ) async {
    final source = (await const BundledLegalTorrentApi().findByContent(
      const MediaRef(id: 10378, type: MediaType.movie),
    )).single;
    final cache = await _newCache(tester);
    final engine = NativeTorrentEngine(
      cache: cache,
      sessionCacheDirectory: () async => cache.root.path,
    );
    await tester.runAsync(engine.initialize);
    final session = await _mount(tester, source, engine, cache: cache);
    try {
      await _waitUntil(
        tester,
        () => session.visiblePlaybackMs != null,
        timeout: const Duration(seconds: 90),
      );
      final native = await tester.runAsync(engine.engineDiagnostics);
      final metrics = {
        ...session.metrics,
        'bridgeVersion': native!.bridgeVersion,
      };
      binding.reportData ??= {};
      binding.reportData!['coldTorrent'] = metrics;
      debugPrint('[PlayerVerification] ${jsonEncode(metrics)}');
      expect(native.bridgeVersion, nativeBridgeVersion);
      expect(session.service.state.playback?.uri.host, '127.0.0.1');
      expect(session.visiblePlaybackMs!, lessThanOrEqualTo(10000));
      expect(session.fileCompleteAtFirstFrame, isFalse);
      expect(session.sourceLookups, 0);
      expect(
        session.bytesAtFirstFrame,
        lessThan(session.service.state.playback!.file.size),
        reason: 'Playback must begin before the entire video downloads.',
      );
    } finally {
      await session.close(tester);
    }
  }, skip: !_runColdTorrent);
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < timeout) {
    await _pump(tester, const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Condition timed out after $timeout.');
}

Future<void> _pump(WidgetTester tester, Duration duration) async {
  // The macOS test launcher can leave the app inactive (open returns 1).
  // Model an active player window so lifecycle-paused frames cannot deadlock
  // the driver while it exercises the real native renderer and controls.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  // A timeout does not cancel WidgetTester's guarded pump. Let the external
  // process watchdog bound a stalled trial; unwinding here would start cleanup
  // while the original pump is still pending and hide the first failure.
  await tester.pump(duration);
}

Future<void> _showControls(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(Video).last);
  var mouse = _controlMouse;
  if (mouse == null) {
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    _controlMouse = mouse;
    await mouse.addPointer(location: center);
    addTearDown(() async {
      await mouse!.removePointer();
      _controlMouse = null;
    });
  }
  await mouse.moveTo(center + const Offset(1, 1));
  await _pump(tester, const Duration(milliseconds: 150));
}

void _expectMenuBounds(WidgetTester tester) {
  final video = tester.getRect(find.byType(Video).last);
  final menu = tester.getRect(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Material && widget.color == const Color(0xf2232328),
        )
        .last,
  );
  expect(video.contains(menu.topLeft), isTrue);
  expect(video.contains(menu.bottomRight), isTrue);
  expect(menu.width, lessThanOrEqualTo(256.001));
  expect(find.byType(Dialog), findsNothing);
  expect(find.byType(BottomSheet), findsNothing);
}

Future<int?> _select(
  WidgetTester tester,
  String tooltip,
  String id,
  String? title,
  String? language, {
  Player? verifyPlayer,
  String? nativeProperty,
}) async {
  await _showControls(tester);
  await tester.tap(find.byTooltip(tooltip).last);
  await _pump(tester, const Duration(milliseconds: 400));
  _expectMenuBounds(tester);
  final row = find.widgetWithText(
    ListTile,
    controlsTrackLabel(id, title, language),
  );
  await tester.ensureVisible(row);
  final elapsed = Stopwatch()..start();
  await tester.tap(row);
  int? acknowledgedMs;
  if (verifyPlayer != null) {
    final native = verifyPlayer.platform as NativePlayer;
    String? actual;
    do {
      actual = await tester.runAsync(() => native.getProperty(nativeProperty!));
      if (actual == id) break;
      await _pump(tester, const Duration(milliseconds: 20));
    } while (elapsed.elapsedMilliseconds < 500);
    acknowledgedMs = elapsed.elapsedMilliseconds;
    expect(
      actual,
      id,
      reason: 'Native $nativeProperty must acknowledge the UI choice.',
    );
    expect(acknowledgedMs, lessThanOrEqualTo(500));
  }
  await _pump(tester, const Duration(milliseconds: 400));
  return acknowledgedMs;
}

Future<void> _expectNativeProperty(
  WidgetTester tester,
  Player player,
  String property,
  String expected,
) async {
  final native = player.platform as NativePlayer;
  final actual = await tester.runAsync(() => native.getProperty(property));
  expect(actual, expected, reason: 'Native $property must confirm the choice.');
}

class _FixtureStorageLocator extends fixture_storage.StorageLocator {
  @override
  Future<(StorageFolder?, StorageFolder?)> read() async => (null, null);
  @override
  Future<void> write(StorageFolder? current, StorageFolder? pending) async =>
      throw StateError('Fixture never changes a storage locator');
}

Future<_IsolatedCache> _newCache(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final temporary = Directory(await appStorage.temporaryDirectoryPath());
      final root = await temporary.createTemp('peerstream-player-test-');
      final isolated = fixture_storage.AppStorage(
        locator: _FixtureStorageLocator(),
        defaultDataPath: () async => '${root.path}/data',
        defaultCachePath: () async => '${root.path}/cache',
        defaultTemporaryPath: () async => '${root.path}/temp',
      );
      final cache = _IsolatedCache(root);
      // This integration target is native-only. The analyzer also checks the
      // conditional memory-store signature, whose storage type is distinct.
      cache.delegate = PlaybackCacheStore(storage: isolated as dynamic);
      return cache;
    }))!;

Future<_Session> _mount(
  WidgetTester tester,
  TorrentSource source,
  TorrentEngine engine, {
  _IsolatedCache? cache,
  Player? sharedPlayer,
  VideoController? sharedVideo,
  StreamingService? sharedService,
}) async {
  cache ??= await _newCache(tester);
  final warmUp = Stopwatch()..start();
  final player = sharedPlayer ?? Player();
  final video = sharedVideo ?? VideoController(player);
  // Production prepares this app-lifetime controller while Home loads.
  var playerReady = false;
  unawaited(video.platform.future.then((_) => playerReady = true));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await _waitUntil(tester, () => playerReady);
  final service =
      sharedService ??
      StreamingService.withExperience(
        engine,
        cache,
        PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
  final session = _Session(player, service, cache);
  session.playerWarmUpMs = warmUp.elapsedMilliseconds;
  session.playerErrors = player.stream.error.listen((error) {
    session.decoderDiagnostics.add(error);
    debugPrint('[FixtureDecoderDiagnostic] $error');
  });
  final container = ProviderContainer(
    overrides: [
      mediaKitPlayerProvider.overrideWithValue(player),
      mediaKitVideoControllerProvider.overrideWithValue(video),
      streamingServiceProvider.overrideWithValue(service),
      playbackCacheProvider.overrideWithValue(cache),
      appSettingsProvider.overrideWith(_TestSettings.new),
      watchHistoryProvider.overrideWith(_TestHistory.new),
      playbackQueueProvider.overrideWith(
        () => PlaybackQueue(store: service.experience),
      ),
      sourcePolicyProvider.overrideWith((ref) async => const SourcePolicy()),
      detailsProvider(source.content)
          .overrideWith((ref) => Completer<MediaDetails>().future),
      sourceResultsProvider((
        media: source.content,
        season: null,
        episode: null,
      )).overrideWith((ref) {
        session.sourceLookups++;
        throw StateError('A selected source must bypass discovery.');
      }),
    ],
  );
  session.container = container;
  final elapsed = Stopwatch()..start();
  session.states = service.states.listen((state) {
    if (state.phase == StreamingPhase.error) {
      debugPrint('[FixturePlaybackError] ${state.message}');
    }
    if (state.phase == StreamingPhase.playing) {
      session.playingMs ??= elapsed.elapsedMilliseconds;
    }
  });
  if (sharedVideo == null) {
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) {
        session.firstFrameMs = elapsed.elapsedMilliseconds;
        session.bytesAtFirstFrame = service.state.stats.downloadedBytes;
        session.fileCompleteAtFirstFrame = service
            .currentTorrentAvailability()
            ?.isComplete;
        debugPrint('[PlayerVerification] ${jsonEncode(session.metrics)}');
      }),
    );
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildPeerStreamTheme(),
        home: DefaultPlayerScreen(
          mediaRef: source.content,
          sourceId: source.id,
          initialSource: source,
        ),
      ),
    ),
  );
  return session;
}

class _Session {
  _Session(this.player, this.service, this.cache);
  final Player player;
  final StreamingService service;
  final _IsolatedCache cache;
  late final ProviderContainer container;
  int? firstFrameMs;
  int? playingMs;
  StreamSubscription<StreamingState>? states;
  StreamSubscription<String>? playerErrors;
  final decoderDiagnostics = <String>[];
  int? get visiblePlaybackMs => firstFrameMs == null || playingMs == null
      ? null
      : (firstFrameMs! > playingMs! ? firstFrameMs : playingMs);
  int playerWarmUpMs = 0;
  bool? fileCompleteAtFirstFrame;
  int bytesAtFirstFrame = 0;
  int sourceLookups = 0;
  Map<String, Object?> get metrics => {
    'firstFrameMs': firstFrameMs,
    'visiblePlaybackMs': visiblePlaybackMs,
    'playerWarmUpMs': playerWarmUpMs,
    'fileCompleteAtFirstFrame': fileCompleteAtFirstFrame,
    'downloadedBytesAtFirstFrame': bytesAtFirstFrame,
    'selectedFileBytes': service.state.playback?.file.size,
    'sourceLookups': sourceLookups,
  };
  Future<void> close(
    WidgetTester tester, {
    bool disposeService = true,
    bool deleteCache = true,
  }) async {
    await states?.cancel();
    await playerErrors?.cancel();
    debugPrint('[PlayerVerification] unmounting test');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    // Cancel paused Riverpod stream subscriptions before awaiting stream close.
    container.dispose();
    debugPrint('[PlayerVerification] test providers disposed');
    await tester.runAsync(() async {
      await player.stop().timeout(const Duration(seconds: 10));
      debugPrint('[PlayerVerification] test player stopped');
      if (disposeService) {
        await service.dispose().timeout(const Duration(seconds: 10));
      } else {
        await service.stop().timeout(const Duration(seconds: 10));
      }
      debugPrint('[PlayerVerification] test service closed');
      if (deleteCache && await cache.root.exists()) {
        await cache.root.delete(recursive: true);
      }
    });
    // Keep libmpv alive until the app exits, matching the production provider.
    // Deleting its wakeup callback early races native teardown in debug builds.
  }
}

class _TestSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(playerVolume: 0);
  @override
  Future<void> setPlayerVolume(double volume) async {}
  @override
  Future<void> setPlayerRate(double rate) async {}
}

class _TestHistory extends WatchHistory {
  @override
  Future<List<WatchEntry>> build() async => [];
  @override
  Future<void> save(WatchEntry entry) async {}
  @override
  Future<void> remove(String key) async {}
  @override
  Future<void> clear() async {}
}

class _IsolatedCache implements PlaybackCacheStore {
  _IsolatedCache(this.root);
  final Directory root;
  PlaybackCacheStore? delegate;
  PlaybackPreferences _preferences = const PlaybackPreferences(
    maxCacheBytes: 512 * 1024 * 1024,
  );
  Future<Directory> directoryFor(TorrentSource source) async =>
      Directory(await directoryPathFor(source)).create(recursive: true);
  @override
  Future<String> directoryPathFor(TorrentSource source) async =>
      delegate?.directoryPathFor(source) ??
      '${root.path}/${torrentCacheKey(source)}';
  @override
  Future<PlaybackCacheEntry?> lookup(TorrentSource source) async =>
      delegate?.lookup(source);
  @override
  Future<PlaybackCacheEntry?> lookupWatch(WatchEntry entry) async =>
      delegate?.lookupWatch(entry);
  @override
  Future<List<PlaybackCacheEntry>> entries() async => delegate?.entries() ?? [];
  @override
  Future<PlaybackCacheEntry?> lookupRequest(
    MediaRef media,
    int? season,
    int? episode,
    String sourceId,
  ) async => delegate?.lookupRequest(media, season, episode, sourceId);
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async =>
      delegate?.completeFile(source);
  @override
  Future<bool> hasCompleteFile(TorrentSource source) async =>
      delegate?.hasCompleteFile(source) ?? false;
  @override
  Future<PlaybackPreferences> preferences() async =>
      delegate?.preferences() ?? _preferences;
  @override
  Future<void> savePreferences(PlaybackPreferences value) async {
    if (delegate != null) {
      await delegate!.savePreferences(value);
    } else {
      _preferences = value;
    }
  }

  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) async {
    await delegate?.record(
      source,
      file,
      complete: complete,
      byteSize: byteSize,
      preserveComplete: preserveComplete,
    );
  }

  @override
  Future<void> recordTimeByteObservation(
    TorrentSource source,
    int positionMs,
    int byteOffset, {
    required int fileSize,
  }) async {
    await delegate?.recordTimeByteObservation(
      source,
      positionMs,
      byteOffset,
      fileSize: fileSize,
    );
  }

  @override
  Future<void> pruneIfNeeded({String? protectedKey}) async {
    await delegate?.pruneIfNeeded(protectedKey: protectedKey);
  }

  @override
  Future<void> clear() async {
    await delegate?.clear();
  }

  @override
  Future<void> remove(String key) async {
    await delegate?.remove(key);
  }

  @override
  Future<void> setPinned(String key, bool pinned) async {
    await delegate?.setPinned(key, pinned);
  }

  @override
  Future<PlaybackCacheSummary> summary() async =>
      delegate?.summary() ??
      PlaybackCacheSummary(
        byteSize: 0,
        maxBytes: _preferences.maxCacheBytes,
        entries: 0,
      );
}

class _DirectOnlyEngine implements TorrentEngine {
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async =>
      throw StateError('Unexpected torrent work');
  @override
  Future<TorrentHandle> add(TorrentSource source) async =>
      throw StateError('Unexpected torrent work');
  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async => [];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => throw StateError('Unexpected torrent work');
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}
}

List<int> _bencode(Object value) {
  if (value is int) return utf8.encode('i${value}e');
  if (value is String) return _bencode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) return [...utf8.encode('${value.length}:'), ...value];
  if (value is List) {
    return [108, for (final item in value) ..._bencode(item as Object), 101];
  }
  final map = value as Map<String, Object>;
  final keys = map.keys.toList()..sort();
  return [
    100,
    for (final key in keys) ...[..._bencode(key), ..._bencode(map[key]!)],
    101,
  ];
}

/// One process per sample keeps player lifetimes and renderer startup comparable.
/// Called only by player_matrix_test.dart, never by normal app startup.
Future<Map<String, dynamic>> runPlayerMatrixTrial(
  WidgetTester tester, {
  required String backend,
  required String kind,
  TorrentSource? sourceOverride,
}) async {
  final cache = await _newCache(tester);
  final seed = await _MatrixVideoSeed.start(tester, _fixturePath);
  final contents = File(Platform.resolvedExecutable).parent.parent.path;
  LocalServiceClient? client;
  final TorrentEngine engine;
  if (kind == 'local' || kind == 'http') {
    engine = _DirectOnlyEngine();
  } else if (backend == 'service') {
    client = LocalServiceClient(
      executable: '$contents/Helpers/peerstream-service',
      library:
          '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
      root: '${cache.root.path}/service',
    );
    cache.delegate = ServicePlaybackCacheStore(client);
    engine = ServiceTorrentEngine(client);
  } else {
    engine = NativeTorrentEngine(
      cache: cache,
      sessionCacheDirectory: () async => cache.root.path,
    );
  }
  final source = sourceOverride ?? seed.source(kind);
  _Session? session;
  StreamSubscription<TorrentStats>? preparing;
  try {
    if (kind == 'warm' || kind == 'partial') {
      if (kind == 'partial') {
        seed.partial = true;
        // Seed a known prefix, then let libtorrent hash-check it. Blocking
        // arbitrary network requests alone depends on its randomized picker.
        final payload = client == null
            ? Directory(await cache.directoryPathFor(source))
            : Directory('${client.root}/payload/${torrentCacheKey(source)}');
        await tester.runAsync(() async {
          await payload.create(recursive: true);
          expect(seed.bytes.length, greaterThan(2 * 1024 * 1024));
          final file = await File('${payload.path}/video.mkv')
              .open(mode: FileMode.write);
          try {
            await file.writeFrom(seed.bytes, 0, 2 * 1024 * 1024);
            await file.truncate(seed.bytes.length);
            await file.flush();
          } finally {
            await file.close();
          }
        });
      }
      await tester.runAsync(engine.initialize);
      final handle = (await tester.runAsync(() => engine.add(source)))!;
      final files = (await tester.runAsync(() => engine.waitForFiles(handle)))!;
      final file = selectVideoFile(files);
      await tester.runAsync(
        () => (engine as OfflineDownloadController).downloadFile(handle, file),
      );
      if (kind == 'warm') {
        var complete = false;
        await _waitUntilAsync(tester, () async {
          complete = await (engine as FileCompletenessChecker).isFileComplete(
            handle,
            file,
          );
          return complete;
        });
        await tester.runAsync(
          () => cache.record(source, file, complete: true, byteSize: file.size),
        );
      } else {
        var downloaded = 0;
        preparing = engine
            .watch(handle)
            .listen((stats) => downloaded = stats.downloadedBytes);
        await _waitUntil(
          tester,
          () => downloaded >= 1024 * 1024,
          timeout: const Duration(seconds: 30),
        );
        expect(
          await tester.runAsync(
            () => (engine as FileCompletenessChecker).isFileComplete(
              handle,
              file,
            ),
          ),
          isFalse,
        );
      }
      await preparing?.cancel();
      preparing = null;
      await tester.runAsync(() => engine.stop(handle));
      seed.releasePartial();
      if (kind == 'warm') seed.metadataAvailable = false;
    }
    session = await _mount(tester, source, engine, cache: cache);
    await _waitUntil(
      tester,
      () => session!.visiblePlaybackMs != null,
      timeout: const Duration(seconds: 30),
    );
    await _pump(tester, const Duration(seconds: 2));
    expect(
      session.decoderDiagnostics.where(
        (error) => error.contains('demuxer-lavf-probesize'),
      ),
      isEmpty,
      reason: 'Profile changes must never send an invalid probe-size sentinel.',
    );
    final audio = realAudioTracks(session.player.state.tracks);
    final subtitles = realSubtitleTracks(session.player.state.tracks);
    expect(audio.length, 2);
    expect(subtitles.length, 2);
    final audioChangeMs = await _select(
      tester,
      'Audio track',
      audio.last.id,
      audio.last.title,
      audio.last.language,
      verifyPlayer: session.player,
      nativeProperty: 'aid',
    );
    final subtitleChangeMs = await _select(
      tester,
      'Subtitle track',
      subtitles.last.id,
      subtitles.last.title,
      subtitles.last.language,
      verifyPlayer: session.player,
      nativeProperty: 'sid',
    );
    final appFootprint = await tester.runAsync(
      () async => _readAppFootprint(contents),
    );
    final childFootprint = engine is ServiceTorrentEngine
        ? (await tester.runAsync(engine.engineDiagnostics))!
                  .processMemoryBytes ??
              0
        : 0;
    expect(appFootprint, isNotNull);
    expect(appFootprint, greaterThan(0));
    if (client != null) expect(childFootprint, greaterThan(0));
    final completeBeforeSeek =
        session.service.state.origin == PlaybackOrigin.cache ||
        session.service.currentTorrentAvailability()?.isComplete == true;
    if (kind == 'warm') expect(completeBeforeSeek, isTrue);
    final seeking = Stopwatch()..start();
    await tester.runAsync(
      () => session!.player.seek(const Duration(seconds: 40)),
    );
    await _waitUntil(
      tester,
      () =>
          (session!.player.state.position - const Duration(seconds: 40)).abs() <
          const Duration(seconds: 2),
      timeout: const Duration(seconds: 30),
    );
    final seekMs = seeking.elapsedMilliseconds;
    final result = <String, dynamic>{
      'backend': backend,
      'kind': kind,
      'bridgeVersion':
          DynamicLibrary.open(
                '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
              )
              .lookupFunction<
                Pointer<Utf8> Function(),
                Pointer<Utf8> Function()
              >('lt_bridge_version')()
              .toDartString(),
      'fixtureSeedPayloadBytes': seed.bytes.length,
      'audioChangeAcknowledgedMs': audioChangeMs,
      'subtitleChangeAcknowledgedMs': subtitleChangeMs,
      ...session.metrics,
      'appPhysicalFootprintBytes': appFootprint,
      'servicePhysicalFootprintBytes': childFootprint,
      'combinedPhysicalFootprintBytes': (appFootprint ?? 0) + childFootprint,
      'seekPositionConfirmedMs': seekMs,
      'playbackOrigin': session.service.state.origin.name,
      'playableScheme': session.service.state.playback?.uri.scheme,
      'fileCompleteBeforeSeek': completeBeforeSeek,
      'seekScope': 'Player position confirmation; not a compositor-frame latency measurement.',
    };
    if (client != null && kind == 'warm') {
      final rows = (await tester.runAsync(cache.entries))!;
      expect(
        rows.any((entry) => entry.source.id == source.id && entry.complete),
        isTrue,
      );
      final oldInstance = client.instance;
      expect(Process.killPid(client.processId!, ProcessSignal.sigkill), isTrue);
      await _waitUntil(
        tester,
        () => session!.service.state.phase == StreamingPhase.error,
      );
      expect(find.text('Retry').evaluate(), isNotEmpty);
      final preferences = (await tester.runAsync(cache.preferences))!;
      expect(client.instance, isNot(oldInstance));
      expect(preferences.preferredAudioLanguage, audio.last.language);
      expect(preferences.preferredSubtitleLanguage, subtitles.last.language);
      result['remoteCacheAdapterRoundTripAndRestartVerified'] = true;
      await tester.tap(find.text('Retry').first);
      await _waitUntil(
        tester,
        () =>
            client!.instance != null &&
            client.instance != oldInstance &&
            session!.service.state.phase == StreamingPhase.playing,
        timeout: const Duration(seconds: 30),
      );
      await _waitUntil(
        tester,
        () => session!.player.state.position >= const Duration(seconds: 38),
        timeout: const Duration(seconds: 30),
      );
      result['helperCrashUiSurvivedAndPositionRecovered'] = true;
    }
    return result;
  } finally {
    await preparing?.cancel();
    seed.releasePartial();
    if (session != null) {
      await session.close(tester);
    } else {
      await tester.runAsync(engine.dispose);
      if (await cache.root.exists()) await cache.root.delete(recursive: true);
    }
    await tester.runAsync(seed.close);
  }
}

Future<void> _waitUntilAsync(
  WidgetTester tester,
  Future<bool> Function() ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await tester.runAsync(ready) == true) return;
    await _pump(tester, const Duration(milliseconds: 100));
  }
  fail('Asynchronous fixture preparation timed out');
}

int? _readAppFootprint(String contents) {
  final library = DynamicLibrary.open(
    '$contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter',
  );
  final read = library
      .lookupFunction<
        Int32 Function(Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint64>, Pointer<Uint64>)
      >('lt_get_process_memory');
  final footprint = calloc<Uint64>();
  final resident = calloc<Uint64>();
  try {
    return read(footprint, resident) == 1 ? footprint.value : null;
  } finally {
    calloc.free(footprint);
    calloc.free(resident);
  }
}

class _MatrixVideoSeed {
  _MatrixVideoSeed(this.server, this.bytes, this.torrent);
  final HttpServer server;
  final Uint8List bytes;
  final List<int> torrent;
  late final StreamSubscription<HttpRequest> subscription;
  bool partial = false;
  bool metadataAvailable = true;
  bool _closed = false;
  final _unblocked = Completer<void>();
  int _nextChunkMicros = 0;
  static String? _sharedFixturePath;
  static Uint8List? _sharedFixtureBytes;
  static Future<_MatrixVideoSeed> start(
    WidgetTester tester,
    String fixture,
  ) async {
    if (_sharedFixturePath != fixture || _sharedFixtureBytes == null) {
      _sharedFixtureBytes = (await tester.runAsync(
        () => File(fixture).readAsBytes(),
      ))!;
      _sharedFixturePath = fixture;
    }
    final bytes = _sharedFixtureBytes!;
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    final pieces = <int>[];
    for (var offset = 0; offset < bytes.length; offset += 256 * 1024) {
      pieces.addAll(
        sha1
            .convert(
              Uint8List.sublistView(
                bytes,
                offset,
                (offset + 256 * 1024).clamp(0, bytes.length),
              ),
            )
            .bytes,
      );
    }
    final torrent = _bencode({
      'info': {
        'name': 'video.mkv',
        'length': bytes.length,
        'piece length': 256 * 1024,
        'pieces': Uint8List.fromList(pieces),
        'nonce': DateTime.now().microsecondsSinceEpoch.toString(),
      },
      'url-list': ['http://127.0.0.1:${server.port}/video.mkv'],
    });
    final seed = _MatrixVideoSeed(server, bytes, torrent);
    seed.subscription = server.listen(seed._serve);
    return seed;
  }

  TorrentSource source(String kind) => TorrentSource(
    id: 'matrix-$kind',
    content: const MediaRef(id: -90909, type: MediaType.movie),
    name: 'Original controlled fixture',
    uri: kind == 'local'
        ? File(_fixturePath).uri
        : Uri.parse(
            'http://127.0.0.1:${server.port}/${kind == 'http' ? 'video.mkv' : 'video.torrent'}',
          ),
    inputType: kind == 'local' || kind == 'http'
        ? TorrentInputType.directUrl
        : TorrentInputType.torrentUrl,
    providerName: 'Original generated fixture',
    attribution: 'Original fixture',
    license: 'CC0',
    provenanceUrl: Uri.parse('about:blank'),
  );
  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.uri.path == '/video.torrent') {
        if (metadataAvailable) {
          request.response.add(torrent);
        } else {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        }
      } else if (request.uri.path == '/video.mkv') {
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        if (request.method == 'HEAD') {
          request.response.contentLength = bytes.length;
          await request.response.close();
          return;
        }
        var start = 0;
        var end = bytes.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final span = range.substring(6).split('-');
          if (span[0].isEmpty) {
            start = (bytes.length - int.parse(span[1])).clamp(0, end);
          } else {
            start = int.parse(span[0]);
            if (span[1].isNotEmpty) end = int.parse(span[1]).clamp(0, end);
          }
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        for (
          var offset = start;
          offset <= end && !_closed;
          offset += 64 * 1024
        ) {
          if (partial && offset >= 2 * 1024 * 1024) await _unblocked.future;
          if (_closed) break;
          final now = DateTime.now().microsecondsSinceEpoch;
          final scheduled = _nextChunkMicros > now ? _nextChunkMicros : now;
          _nextChunkMicros =
              scheduled + 62500; // Shared 1 MiB/s across connections.
          if (scheduled > now) {
            await Future<void>.delayed(Duration(microseconds: scheduled - now));
          }
          request.response.add(
            Uint8List.sublistView(
              bytes,
              offset,
              (offset + 64 * 1024).clamp(0, end + 1),
            ),
          );
          await request.response.flush();
        }
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void releasePartial() {
    partial = false;
    if (!_unblocked.isCompleted) _unblocked.complete();
  }

  Future<void> close() async {
    _closed = true;
    releasePartial();
    await subscription.cancel();
    await server.close(force: true);
  }
}
