import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_forge_player/media_forge_player.dart'
    show VideoEnhancementCapabilities, VideoEnhancementMode;

import '../core/config.dart';
import '../services/torrent/torrent_engine.dart';
import '../providers/app_providers.dart';
import '../services/settings/settings_store.dart';

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  AppSettingsNotifier({
    Future<AppSettings> Function()? read,
    Future<void> Function(AppSettings)? write,
  }) : _read = read ?? readAppSettings,
       _write = write ?? writeAppSettings;

  final Future<AppSettings> Function() _read;
  final Future<void> Function(AppSettings) _write;
  Future<void> _tail = Future.value();

  @override
  Future<AppSettings> build() => _read();

  Future<void> _change(AppSettings Function(AppSettings) update) {
    final next = _tail.then((_) async {
      final current = state.value ?? await _read();
      final updated = update(current);
      await _write(updated);
      state = AsyncData(updated);
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> setSubtitleLanguage(String? language) => _change(
    (current) => current.copyWith(preferredSubtitleLanguage: language),
  );

  Future<void> setAudioLanguage(String? language) =>
      _change((current) => current.copyWith(preferredAudioLanguage: language));

  Future<void> setAutoLoadSubtitles(bool value) =>
      _change((current) => current.copyWith(autoLoadSubtitles: value));

  Future<void> setStreamingCatalogsEnabled(bool value) =>
      _change((current) => current.copyWith(streamingCatalogsEnabled: value));

  Future<void> setUseMediaForgePlayer(bool value) =>
      _change((current) => current.copyWith(useMediaForgePlayer: value));

  Future<void> setMediaForgeVideoEnhancementMode(VideoEnhancementMode value) =>
      _change(
        (current) => current.copyWith(mediaForgeVideoEnhancementMode: value),
      );

  Future<void> setResourceProfile(PlaybackResourceProfile profile) =>
      _change((current) => current.copyWith(resourceProfile: profile));

  Future<void> setAutoplay(bool value) =>
      _change((current) => current.copyWith(autoplay: value));

  Future<void> setPlayerVolume(double volume) =>
      _change((current) => current.copyWith(playerVolume: volume));

  Future<void> setPlayerRate(double rate) =>
      _change((current) => current.copyWith(playerRate: rate));

  Future<void> setSubtitleTextScale(double scale) =>
      _change((current) => current.copyWith(subtitleTextScale: scale));

  Future<void> setSubtitleBackground(SubtitleBackgroundStyle style) =>
      _change((current) => current.copyWith(subtitleBackground: style));
}

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
      AppSettingsNotifier.new,
    );

/// Capabilities observed from the active MediaForge session. Keeping this
/// session-scoped avoids starting MediaForge merely to render Settings.
class MediaForgeVideoEnhancementCapabilitiesNotifier
    extends Notifier<VideoEnhancementCapabilities?> {
  @override
  VideoEnhancementCapabilities? build() => null;

  void setCapabilities(VideoEnhancementCapabilities? capabilities) {
    state = capabilities;
  }
}

final mediaForgeVideoEnhancementCapabilitiesProvider =
    NotifierProvider<
      MediaForgeVideoEnhancementCapabilitiesNotifier,
      VideoEnhancementCapabilities?
    >(MediaForgeVideoEnhancementCapabilitiesNotifier.new);

class AppInfo {
  const AppInfo({
    required this.appVersion,
    required this.nativeBuildIdentity,
    required this.tmdbConfigured,
    required this.streamingCatalogsConfigured,
    required this.engineSupported,
    this.engineUnsupportedReason,
  });

  final String appVersion;
  final String nativeBuildIdentity;
  final bool tmdbConfigured;
  final bool streamingCatalogsConfigured;
  final bool engineSupported;
  final String? engineUnsupportedReason;
}

final appInfoProvider = FutureProvider<AppInfo>((ref) async {
  final service = ref.watch(streamingServiceProvider);
  final engine = service.engine;
  String? unsupportedReason;
  if (!engine.isSupported) {
    unsupportedReason = engine.unsupportedReason;
  }
  return AppInfo(
    appVersion: '1.0.0',
    nativeBuildIdentity: service.nativeBuildIdentity,
    tmdbConfigured: AppConfig.hasTmdbToken,
    streamingCatalogsConfigured: AppConfig.hasStreamingCatalogs,
    engineSupported: engine.isSupported,
    engineUnsupportedReason: unsupportedReason,
  );
});
