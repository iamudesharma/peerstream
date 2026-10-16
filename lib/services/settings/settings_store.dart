import 'settings_values.dart';
import '../torrent/torrent_engine.dart';
import '../storage/storage_location.dart';

import 'package:media_forge_player/media_forge_player.dart'
    show VideoEnhancementMode;

/// Background behind player-rendered subtitles.
enum SubtitleBackgroundStyle { none, translucent, solid }

class AppSettings {
  const AppSettings({
    this.preferredSubtitleLanguage,
    this.preferredAudioLanguage,
    this.autoLoadSubtitles = false,
    this.streamingCatalogsEnabled = true,
    this.useMediaForgePlayer = false,
    this.mediaForgeVideoEnhancementMode = VideoEnhancementMode.off,
    this.resourceProfile = PlaybackResourceProfile.balanced,
    this.autoplay = false,
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

  /// Presentation-only GPU enhancement default for future experimental
  /// MediaForge sessions. The standard media_kit player never reads it.
  final VideoEnhancementMode mediaForgeVideoEnhancementMode;

  /// Last player volume (0–100), restored when the player opens.
  final PlaybackResourceProfile resourceProfile;
  final bool autoplay;
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
    VideoEnhancementMode? mediaForgeVideoEnhancementMode,
    PlaybackResourceProfile? resourceProfile,
    bool? autoplay,
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
    mediaForgeVideoEnhancementMode:
        mediaForgeVideoEnhancementMode ?? this.mediaForgeVideoEnhancementMode,
    resourceProfile: resourceProfile ?? this.resourceProfile,
    autoplay: autoplay ?? this.autoplay,
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
const _kMediaForgeVideoEnhancementMode =
    'settings.media_forge_video_enhancement_mode';
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
    final prefs = await readSettingsValues();
    return AppSettings(
      preferredSubtitleLanguage: (prefs[_kSubtitleLanguage] as String?),
      preferredAudioLanguage: (prefs[_kAudioLanguage] as String?),
      autoLoadSubtitles: (prefs[_kAutoLoadSubtitles] as bool?) ?? false,
      streamingCatalogsEnabled:
          (prefs[_kStreamingCatalogsEnabled] as bool?) ?? true,
      useMediaForgePlayer: (prefs[_kUseMediaForgePlayer] as bool?) ?? false,
      mediaForgeVideoEnhancementMode: VideoEnhancementMode.fromWireName(
        (prefs[_kMediaForgeVideoEnhancementMode] as String?) ??
            VideoEnhancementMode.off.wireName,
      ),
      resourceProfile: prefs['settings.resource_profile'] == 'lowMemory'
          ? PlaybackResourceProfile.lowMemory
          : PlaybackResourceProfile.balanced,
      autoplay: prefs['settings.autoplay'] == true,
      playerVolume: (prefs[_kPlayerVolume] as num?)?.toDouble() ?? 100,
      playerRate: (prefs[_kPlayerRate] as num?)?.toDouble() ?? 1,
      subtitleTextScale: (prefs[_kSubtitleTextScale] as num?)?.toDouble() ?? 1,
      subtitleBackground: _parseSubtitleBackground(
        (prefs[_kSubtitleBackground] as String?),
      ),
    );
  } on StorageUnavailableException {
    rethrow;
  } catch (_) {
    return const AppSettings();
  }
}

Future<void> writeAppSettings(AppSettings settings) async {
  await writeSettingsValues({
    _kSubtitleLanguage: settings.preferredSubtitleLanguage,
    _kAudioLanguage: settings.preferredAudioLanguage,
    _kAutoLoadSubtitles: settings.autoLoadSubtitles,
    _kStreamingCatalogsEnabled: settings.streamingCatalogsEnabled,
    _kUseMediaForgePlayer: settings.useMediaForgePlayer,
    _kMediaForgeVideoEnhancementMode:
        settings.mediaForgeVideoEnhancementMode.wireName,
    'settings.resource_profile': settings.resourceProfile.name,
    'settings.autoplay': settings.autoplay,
    _kPlayerVolume: settings.playerVolume,
    _kPlayerRate: settings.playerRate,
    _kSubtitleTextScale: settings.subtitleTextScale,
    _kSubtitleBackground: settings.subtitleBackground.name,
  });
}
