import 'package:shared_preferences/shared_preferences.dart';

/// Background behind player-rendered subtitles.
enum SubtitleBackgroundStyle { none, translucent, solid }

class AppSettings {
  const AppSettings({
    this.preferredSubtitleLanguage,
    this.preferredAudioLanguage,
    this.autoLoadSubtitles = false,
    this.streamingCatalogsEnabled = true,
    this.useMediaForgePlayer = false,
    this.playerVolume = 100,
    this.playerRate = 1,
    this.subtitleTextScale = 1,
    this.subtitleBackground = SubtitleBackgroundStyle.translucent,
  });

  final String? preferredSubtitleLanguage;
  final String? preferredAudioLanguage;
  final bool autoLoadSubtitles;
  final bool streamingCatalogsEnabled;

  /// Experimental MediaForge playback backend. Default false: existing
  /// media_kit player is used. Persisted; applies on next media open.
  final bool useMediaForgePlayer;

  /// Last player volume (0–100), restored when the player opens.
  final double playerVolume;

  /// Last playback speed, restored when the player opens.
  final double playerRate;

  /// Multiplier applied to the subtitle font size (see
  /// [subtitleTextScales]).
  final double subtitleTextScale;

  /// Background behind player-rendered subtitles.
  final SubtitleBackgroundStyle subtitleBackground;

  /// Player subtitle size presets and their user-facing labels.
  static const subtitleTextScales = <double>[0.8, 1, 1.25, 1.5];

  static String subtitleTextScaleLabel(double scale) => switch (scale) {
    0.8 => 'Small',
    1.25 => 'Large',
    1.5 => 'Huge',
    _ => 'Medium',
  };

  static String subtitleBackgroundLabel(SubtitleBackgroundStyle style) =>
      switch (style) {
        SubtitleBackgroundStyle.none => 'None',
        SubtitleBackgroundStyle.solid => 'Solid',
        SubtitleBackgroundStyle.translucent => 'Translucent',
      };

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
    double? playerVolume,
    double? playerRate,
    double? subtitleTextScale,
    SubtitleBackgroundStyle? subtitleBackground,
  }) => AppSettings(
    preferredSubtitleLanguage:
        preferredSubtitleLanguage ?? this.preferredSubtitleLanguage,
    preferredAudioLanguage:
        preferredAudioLanguage ?? this.preferredAudioLanguage,
    autoLoadSubtitles: autoLoadSubtitles ?? this.autoLoadSubtitles,
    streamingCatalogsEnabled:
        streamingCatalogsEnabled ?? this.streamingCatalogsEnabled,
    useMediaForgePlayer: useMediaForgePlayer ?? this.useMediaForgePlayer,
    playerVolume: playerVolume ?? this.playerVolume,
    playerRate: playerRate ?? this.playerRate,
    subtitleTextScale: subtitleTextScale ?? this.subtitleTextScale,
    subtitleBackground: subtitleBackground ?? this.subtitleBackground,
  );
}

const _kSubtitleLanguage = 'settings.subtitle_language';
const _kAudioLanguage = 'settings.audio_language';
const _kAutoLoadSubtitles = 'settings.auto_load_subtitles';
const _kStreamingCatalogsEnabled = 'settings.streaming_catalogs_enabled';
const _kUseMediaForgePlayer = 'settings.use_media_forge_player';
const _kPlayerVolume = 'settings.player_volume';
const _kPlayerRate = 'settings.player_rate';
const _kSubtitleTextScale = 'settings.subtitle_text_scale';
const _kSubtitleBackground = 'settings.subtitle_background';

SubtitleBackgroundStyle _parseSubtitleBackground(String? value) {
  for (final style in SubtitleBackgroundStyle.values) {
    if (style.name == value) return style;
  }
  return SubtitleBackgroundStyle.translucent;
}

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
      playerVolume: prefs.getDouble(_kPlayerVolume) ?? 100,
      playerRate: prefs.getDouble(_kPlayerRate) ?? 1,
      subtitleTextScale: prefs.getDouble(_kSubtitleTextScale) ?? 1,
      subtitleBackground: _parseSubtitleBackground(
        prefs.getString(_kSubtitleBackground),
      ),
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
      await prefs.setString(_kAudioLanguage, settings.preferredAudioLanguage!);
    } else {
      await prefs.remove(_kAudioLanguage);
    }
    await prefs.setBool(_kAutoLoadSubtitles, settings.autoLoadSubtitles);
    await prefs.setBool(
      _kStreamingCatalogsEnabled,
      settings.streamingCatalogsEnabled,
    );
    await prefs.setBool(_kUseMediaForgePlayer, settings.useMediaForgePlayer);
    await prefs.setDouble(_kPlayerVolume, settings.playerVolume);
    await prefs.setDouble(_kPlayerRate, settings.playerRate);
    await prefs.setDouble(_kSubtitleTextScale, settings.subtitleTextScale);
    await prefs.setString(
      _kSubtitleBackground,
      settings.subtitleBackground.name,
    );
  } catch (_) {}
}
