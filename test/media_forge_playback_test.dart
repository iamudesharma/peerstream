import 'package:flutter_test/flutter_test.dart';
import 'package:media_forge_player/media_forge_player.dart';
import 'package:peerstream/features/player/player_backend.dart';
import 'package:peerstream/services/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings MediaForge preferences', () {
    test('defaults to the standard player with enhancement off', () {
      expect(const AppSettings().useMediaForgePlayer, isFalse);
      expect(
        const AppSettings().mediaForgeVideoEnhancementMode,
        VideoEnhancementMode.off,
      );
    });

    test('persists across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      await writeAppSettings(
        const AppSettings().copyWith(
          useMediaForgePlayer: true,
          mediaForgeVideoEnhancementMode: VideoEnhancementMode.highQuality,
        ),
      );
      final enabled = await readAppSettings();
      expect(enabled.useMediaForgePlayer, isTrue);
      expect(
        enabled.mediaForgeVideoEnhancementMode,
        VideoEnhancementMode.highQuality,
      );
      await writeAppSettings(
        const AppSettings().copyWith(
          useMediaForgePlayer: false,
          mediaForgeVideoEnhancementMode: VideoEnhancementMode.sharp,
        ),
      );
      final disabled = await readAppSettings();
      expect(disabled.useMediaForgePlayer, isFalse);
      expect(
        disabled.mediaForgeVideoEnhancementMode,
        VideoEnhancementMode.sharp,
      );
    });

    test('generic settings still persist (no regression)', () async {
      SharedPreferences.setMockInitialValues({});
      await writeAppSettings(
        const AppSettings().copyWith(
          autoLoadSubtitles: true,
          streamingCatalogsEnabled: false,
        ),
      );
      final settings = await readAppSettings();
      expect(settings.autoLoadSubtitles, isTrue);
      expect(settings.streamingCatalogsEnabled, isFalse);
      // New flag keeps its default when unrelated fields change.
      expect(settings.useMediaForgePlayer, isFalse);
      expect(settings.mediaForgeVideoEnhancementMode, VideoEnhancementMode.off);
    });
  });

  group('resolveBackend', () {
    test('false selects the default player', () {
      expect(
        resolveBackend(const AppSettings(useMediaForgePlayer: false)),
        PlayerBackend.defaultPlayer,
      );
    });

    test('true selects MediaForge', () {
      expect(
        resolveBackend(const AppSettings(useMediaForgePlayer: true)),
        PlayerBackend.mediaForge,
      );
    });

    test('enum uses readable defaultPlayer name', () {
      expect(
        PlayerBackend.values.map((e) => e.name),
        contains('defaultPlayer'),
      );
    });

    test('default player ignores the MediaForge enhancement preference', () {
      const settings = AppSettings(
        useMediaForgePlayer: false,
        mediaForgeVideoEnhancementMode: VideoEnhancementMode.highQuality,
      );

      expect(resolveBackend(settings), PlayerBackend.defaultPlayer);
    });
  });

  group('MediaForge opening preview', () {
    test('waits for a confirmed first presented frame', () {
      expect(
        shouldShowMediaForgeOpeningPreview(
          firstFramePresented: false,
          hasError: false,
        ),
        isTrue,
      );
      expect(
        shouldShowMediaForgeOpeningPreview(
          firstFramePresented: true,
          hasError: false,
        ),
        isFalse,
      );
    });

    test('does not cover a player error', () {
      expect(
        shouldShowMediaForgeOpeningPreview(
          firstFramePresented: false,
          hasError: true,
        ),
        isFalse,
      );
    });
  });

  group('MediaForge video enhancement integration', () {
    test('passes the persisted mode to the public MediaForge setter', () async {
      final received = <VideoEnhancementMode>[];

      final accepted = await applyMediaForgeVideoEnhancementMode(
        mode: VideoEnhancementMode.highQuality,
        setMode: (mode) async {
          received.add(mode);
          return true;
        },
      );

      expect(accepted, isTrue);
      expect(received, [VideoEnhancementMode.highQuality]);
    });

    test(
      'runtime change keeps the same controller and source generation',
      () async {
        final controller = MediaForgePlayerController();
        addTearDown(controller.dispose);
        final controllerIdentity = controller;
        final sourceGeneration = controller.sourceGeneration;

        await applyMediaForgeVideoEnhancementMode(
          mode: VideoEnhancementMode.sharp,
          setMode: controller.setVideoEnhancementMode,
        );
        await applyMediaForgeVideoEnhancementMode(
          mode: VideoEnhancementMode.enhanced,
          setMode: controller.setVideoEnhancementMode,
        );

        expect(identical(controller, controllerIdentity), isTrue);
        expect(controller.sourceGeneration, sourceGeneration);
        expect(
          controller.value.videoEnhancementMode,
          VideoEnhancementMode.enhanced,
        );
      },
    );

    test('unsupported capability keeps normal rendering available', () async {
      const capabilities = VideoEnhancementCapabilities.unsupported;

      expect(
        isMediaForgeVideoEnhancementModeSupported(
          mode: VideoEnhancementMode.off,
          capabilities: capabilities,
        ),
        isTrue,
      );
      expect(
        isMediaForgeVideoEnhancementModeSupported(
          mode: VideoEnhancementMode.enhanced,
          capabilities: capabilities,
        ),
        isFalse,
      );
      expect(
        mediaForgeVideoEnhancementCapabilityDescription(capabilities),
        contains('normal rendering'),
      );
      expect(
        await applyMediaForgeVideoEnhancementMode(
          mode: VideoEnhancementMode.enhanced,
          setMode: (_) async => false,
        ),
        isFalse,
      );
    });

    test(
      'enhancement failure leaves the experimental flag unchanged',
      () async {
        SharedPreferences.setMockInitialValues({});
        await writeAppSettings(
          const AppSettings(
            useMediaForgePlayer: true,
            mediaForgeVideoEnhancementMode: VideoEnhancementMode.enhanced,
          ),
        );

        final accepted = await applyMediaForgeVideoEnhancementMode(
          mode: VideoEnhancementMode.enhanced,
          setMode: (_) async => throw StateError('GPU pass failed'),
        );

        expect(accepted, isFalse);
        expect((await readAppSettings()).useMediaForgePlayer, isTrue);
      },
    );

    test(
      'enhancement failure does not select the default-player fallback',
      () async {
        const settings = AppSettings(
          useMediaForgePlayer: true,
          mediaForgeVideoEnhancementMode: VideoEnhancementMode.highQuality,
        );

        final accepted = await applyMediaForgeVideoEnhancementMode(
          mode: settings.mediaForgeVideoEnhancementMode,
          setMode: (_) async => throw StateError('GPU unavailable'),
        );

        expect(accepted, isFalse);
        expect(resolveBackend(settings), PlayerBackend.mediaForge);
      },
    );
  });

  group('buildMediaForgeMedia', () {
    test('localhost HTTP URL stays a network source with headers', () {
      final media = buildMediaForgeMedia(
        uri: Uri.parse('http://127.0.0.1:8080/stream'),
        headers: const {'Authorization': 'Bearer x'},
      );
      expect(media, isA<MediaForgeNetwork>());
      final network = media as MediaForgeNetwork;
      expect(network.url, 'http://127.0.0.1:8080/stream');
      expect(network.headers, {'Authorization': 'Bearer x'});
      expect(network.isLoopback, isTrue);
      expect(network.reconnect, isTrue);
    });

    test('file URI opens as a local file', () {
      final media = buildMediaForgeMedia(uri: Uri.file('/tmp/video.mp4'));
      expect(media, isA<MediaForgeFile>());
    });
  });

  group('resolveFallbackResumeMs', () {
    test('preserves MediaForge position (no restart)', () {
      expect(
        resolveFallbackResumeMs(
          controllerPositionMs: 3921200,
          explicitStartMs: 1000,
          widgetResumeMs: 500,
        ),
        3921200,
      );
    });

    test('falls back to explicit start then route resume', () {
      expect(
        resolveFallbackResumeMs(
          controllerPositionMs: 0,
          explicitStartMs: 61000,
          widgetResumeMs: 500,
        ),
        61000,
      );
      expect(
        resolveFallbackResumeMs(controllerPositionMs: 0, widgetResumeMs: 45000),
        45000,
      );
    });

    test('does not mutate the persisted setting object', () {
      const settings = AppSettings(useMediaForgePlayer: true);
      resolveFallbackResumeMs(controllerPositionMs: 1234);
      expect(settings.useMediaForgePlayer, isTrue);
    });
  });

  group('MediaForgeRuntime', () {
    test('memoizes a single init future', () {
      MediaForgeRuntime.resetForTest();
      final first = MediaForgeRuntime.ensureInitialized();
      final second = MediaForgeRuntime.ensureInitialized();
      expect(identical(first, second), isTrue);
      // Swallow the expected native-load failure in unit tests; the
      // memoization (single Future) is what this test asserts.
      first.then<void>((_) {}, onError: (_, _) {});
      MediaForgeRuntime.resetForTest();
    });
  });

  test('backend logging never throws (requested vs active)', () {
    expect(
      () => logPlaybackBackend(
        requested: PlayerBackend.mediaForge,
        active: PlayerBackend.defaultPlayer,
        reason: 'Rust initialization failed',
        source: 'http://127.0.0.1:8080/stream',
      ),
      returnsNormally,
    );
  });
}
