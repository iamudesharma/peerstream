import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppSettings defaults cover player and subtitle preferences', () {
    const defaults = AppSettings();
    expect(defaults.playerVolume, 100);
    expect(defaults.playerRate, 1);
    expect(defaults.subtitleTextScale, 1);
    expect(defaults.subtitleBackground, SubtitleBackgroundStyle.translucent);
  });

  test('copyWith replaces player preferences and keeps unrelated fields', () {
    final updated = const AppSettings(useMediaForgePlayer: true).copyWith(
      playerVolume: 42,
      playerRate: 1.5,
      subtitleTextScale: 1.25,
      subtitleBackground: SubtitleBackgroundStyle.solid,
    );
    expect(updated.playerVolume, 42);
    expect(updated.playerRate, 1.5);
    expect(updated.subtitleTextScale, 1.25);
    expect(updated.subtitleBackground, SubtitleBackgroundStyle.solid);
    expect(updated.useMediaForgePlayer, isTrue);
  });

  test('player preferences round-trip through SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final written = (await readAppSettings()).copyWith(
      playerVolume: 35,
      playerRate: 1.25,
      subtitleTextScale: 1.5,
      subtitleBackground: SubtitleBackgroundStyle.none,
    );
    await writeAppSettings(written);

    final read = await readAppSettings();
    expect(read.playerVolume, 35);
    expect(read.playerRate, 1.25);
    expect(read.subtitleTextScale, 1.5);
    expect(read.subtitleBackground, SubtitleBackgroundStyle.none);
  });

  test('subtitle labels exist for every option', () {
    for (final scale in AppSettings.subtitleTextScales) {
      expect(AppSettings.subtitleTextScaleLabel(scale), isNotEmpty);
    }
    for (final style in SubtitleBackgroundStyle.values) {
      expect(AppSettings.subtitleBackgroundLabel(style), isNotEmpty);
    }
  });
}
