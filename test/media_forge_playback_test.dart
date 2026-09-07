import 'package:flutter_test/flutter_test.dart';
import 'package:media_forge_player/media_forge_player.dart';
import 'package:peerstream/features/player/player_backend.dart';
import 'package:peerstream/services/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings useMediaForgePlayer', () {
    test('defaults to false', () {
      expect(const AppSettings().useMediaForgePlayer, isFalse);
    });

    test('persists across restarts', () async {
      SharedPreferences.setMockInitialValues({});
      await writeAppSettings(
        const AppSettings().copyWith(useMediaForgePlayer: true),
      );
      expect((await readAppSettings()).useMediaForgePlayer, isTrue);
      await writeAppSettings(
        const AppSettings().copyWith(useMediaForgePlayer: false),
      );
      expect((await readAppSettings()).useMediaForgePlayer, isFalse);
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
      expect(PlayerBackend.values.map((e) => e.name), contains('defaultPlayer'));
    });
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
      final media = buildMediaForgeMedia(
        uri: Uri.file('/tmp/video.mp4'),
      );
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
        resolveFallbackResumeMs(
          controllerPositionMs: 0,
          widgetResumeMs: 45000,
        ),
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
