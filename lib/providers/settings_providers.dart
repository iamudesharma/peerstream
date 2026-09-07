import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../providers/app_providers.dart';
import '../services/settings/settings_store.dart';

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => readAppSettings();

  Future<void> _save(AppSettings settings) async {
    await writeAppSettings(settings);
    state = AsyncData(settings);
  }

  Future<void> setSubtitleLanguage(String? language) async {
    final current = state.value ?? await readAppSettings();
    final updated = current.copyWith(preferredSubtitleLanguage: language);
    await _save(updated);
  }

  Future<void> setAudioLanguage(String? language) async {
    final current = state.value ?? await readAppSettings();
    final updated = current.copyWith(preferredAudioLanguage: language);
    await _save(updated);
  }

  Future<void> setAutoLoadSubtitles(bool value) async {
    final current = state.value ?? await readAppSettings();
    final updated = current.copyWith(autoLoadSubtitles: value);
    await _save(updated);
  }

  Future<void> setStreamingCatalogsEnabled(bool value) async {
    final current = state.value ?? await readAppSettings();
    final updated = current.copyWith(streamingCatalogsEnabled: value);
    await _save(updated);
  }

  Future<void> setUseMediaForgePlayer(bool value) async {
    final current = state.value ?? await readAppSettings();
    final updated = current.copyWith(useMediaForgePlayer: value);
    await _save(updated);
  }
}

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

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
