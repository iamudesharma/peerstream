import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    this.preferredSubtitleLanguage,
    this.preferredAudioLanguage,
    this.autoLoadSubtitles = false,
    this.streamingCatalogsEnabled = true,
    this.useMediaForgePlayer = false,
  });

  final String? preferredSubtitleLanguage;
  final String? preferredAudioLanguage;
  final bool autoLoadSubtitles;
  final bool streamingCatalogsEnabled;

  /// Experimental MediaForge playback backend. Default false: existing
  /// media_kit player is used. Persisted; applies on next media open.
  final bool useMediaForgePlayer;

  static const _defaultSubtitleLanguages = [
    'None',
    'English',
    'Spanish',
    'French',
    'German',
    'Italian',
    'Portuguese',
    'Dutch',
    'Russian',
    'Japanese',
    'Korean',
    'Chinese',
    'Arabic',
    'Hindi',
  ];

  static const _defaultAudioLanguages = [
    'Default',
    'English',
    'Spanish',
    'French',
    'German',
    'Italian',
    'Portuguese',
    'Dutch',
    'Russian',
    'Japanese',
    'Korean',
    'Chinese',
    'Arabic',
    'Hindi',
  ];

  static List<String> get subtitleLanguages => _defaultSubtitleLanguages;
  static List<String> get audioLanguages => _defaultAudioLanguages;

  AppSettings copyWith({
    String? preferredSubtitleLanguage,
    String? preferredAudioLanguage,
    bool? autoLoadSubtitles,
    bool? streamingCatalogsEnabled,
    bool? useMediaForgePlayer,
  }) =>
      AppSettings(
        preferredSubtitleLanguage:
            preferredSubtitleLanguage ?? this.preferredSubtitleLanguage,
        preferredAudioLanguage:
            preferredAudioLanguage ?? this.preferredAudioLanguage,
        autoLoadSubtitles: autoLoadSubtitles ?? this.autoLoadSubtitles,
        streamingCatalogsEnabled:
            streamingCatalogsEnabled ?? this.streamingCatalogsEnabled,
        useMediaForgePlayer:
            useMediaForgePlayer ?? this.useMediaForgePlayer,
      );
}

const _kSubtitleLanguage = 'settings.subtitle_language';
const _kAudioLanguage = 'settings.audio_language';
const _kAutoLoadSubtitles = 'settings.auto_load_subtitles';
const _kStreamingCatalogsEnabled = 'settings.streaming_catalogs_enabled';
const _kUseMediaForgePlayer = 'settings.use_media_forge_player';

Future<AppSettings> readAppSettings() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      preferredSubtitleLanguage: prefs.getString(_kSubtitleLanguage),
      preferredAudioLanguage: prefs.getString(_kAudioLanguage),
      autoLoadSubtitles: prefs.getBool(_kAutoLoadSubtitles) ?? false,
      streamingCatalogsEnabled:
          prefs.getBool(_kStreamingCatalogsEnabled) ?? true,
      useMediaForgePlayer: prefs.getBool(_kUseMediaForgePlayer) ?? false,
    );
  } catch (_) {
    return const AppSettings();
  }
}

Future<void> writeAppSettings(AppSettings settings) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (settings.preferredSubtitleLanguage != null) {
      await prefs.setString(
        _kSubtitleLanguage,
        settings.preferredSubtitleLanguage!,
      );
    } else {
      await prefs.remove(_kSubtitleLanguage);
    }
    if (settings.preferredAudioLanguage != null) {
      await prefs.setString(
        _kAudioLanguage,
        settings.preferredAudioLanguage!,
      );
    } else {
      await prefs.remove(_kAudioLanguage);
    }
    await prefs.setBool(_kAutoLoadSubtitles, settings.autoLoadSubtitles);
    await prefs.setBool(
      _kStreamingCatalogsEnabled,
      settings.streamingCatalogsEnabled,
    );
    await prefs.setBool(_kUseMediaForgePlayer, settings.useMediaForgePlayer);
  } catch (_) {}
}
