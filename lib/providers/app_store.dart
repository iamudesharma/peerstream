import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dio/dio.dart';

import '../core/config.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/saved_item.dart';
import '../models/season.dart';
import '../models/watch_progress.dart';
import '../repositories/media_repository.dart';
import '../services/history/watch_history_store.dart';
import '../services/mylist/my_list_store.dart';
import '../services/playback/playback_cache.dart';
import '../services/settings/settings_store.dart';
import '../services/streaming/source_ranking.dart';
import '../services/streaming/streaming_service.dart';
import '../services/stremio/stremio_catalog_service.dart';
import '../services/subtitles/subtitle_provider.dart';
import '../services/tmdb/tmdb_service.dart';
import '../services/torrent/addon_provider.dart';
import '../services/torrent/addon_settings.dart';
import '../services/torrent/bundled_torrent_api.dart';
import '../services/torrent/provider_cache.dart';
import '../services/torrent/provider_catalog.dart';
import '../services/torrent/source_discovery.dart';
import '../services/torrent/source_policy.dart';
import '../services/torrent/source_policy_loader.dart';
import '../services/torrent/torrent_engine.dart';
import '../services/torrent/torrent_engine_factory.dart';
import '../services/torrent/torrent_provider.dart';
import 'loadable.dart';

typedef SourceRequest = ({MediaRef media, int? season, int? episode});
typedef CategoryRequest = ({MediaType type, int genreId, int page});
typedef SeasonRequest = ({int seriesId, int seasonNumber});
typedef StreamingCatalogRequest = ({MediaType type, String catalogId});

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

/// App-wide services and the notifiers screens watch.
class AppStore {
  AppStore._() {
    streaming = StreamingService(createTorrentEngine(), cache);
    unawaited(streaming.warmUp());
    streamingState = StreamLoadable<StreamingState>(
      (() async* {
        yield streaming.state;
        yield* streaming.states;
      })(),
      initial: streaming.state,
    );
    playbackPhase = StreamLoadable<StreamingPhase>(
      streamingStateStream.map((state) => state.phase),
      initial: streaming.state.phase,
    );
  }

  static final instance = AppStore._();

  final tmdb = TmdbService();
  final catalogs = StremioCatalogService();
  late final MediaRepository media = MediaRepository(
    tmdb,
    AppConfig.hasStreamingCatalogs ? catalogs : null,
  );
  late final AddonSubtitleProvider subtitles = AddonSubtitleProvider(
    resolveImdbId: media.imdbId,
  );
  final bundled = const BundledLegalTorrentApi();
  late final TorrentProvider torrents = WebTorrentLegalDemoProvider(
    api: bundled,
  );
  final cache = PlaybackCacheStore();
  late final StreamingService streaming;
  late final StreamLoadable<StreamingState> streamingState;
  late final StreamLoadable<StreamingPhase> playbackPhase;

  Stream<StreamingState> get streamingStateStream => streaming.states;

  final policy = Loadable<SourcePolicy>(loadSourcePolicy);
  final addonUrls = AddonUrlsController();
  final history = WatchHistoryController();
  final myList = MyListController();
  final settings = SettingsController();

  late final trendingMovies = Loadable<List<MediaItem>>(
    () => media.trendingMovies(),
  );
  late final trendingSeries = Loadable<List<MediaItem>>(
    () => media.trendingSeries(),
  );
  late final popularMovies = Loadable<List<MediaItem>>(
    () => media.popularMovies(),
  );
  late final streamingCatalogs = Loadable<List<StremioCatalog>>(() {
    if (!AppConfig.hasStreamingCatalogs) return Future.value(const []);
    return catalogs.catalogs();
  });
  late final cacheSummary = Loadable(() => cache.summary());
  late final cacheEntries = Loadable(() => cache.entries());
  late final appInfo = Loadable<AppInfo>(() async {
    final engine = streaming.engine;
    return AppInfo(
      appVersion: '1.0.0',
      nativeBuildIdentity: streaming.nativeBuildIdentity,
      tmdbConfigured: AppConfig.hasTmdbToken,
      streamingCatalogsConfigured: AppConfig.hasStreamingCatalogs,
      engineSupported: engine.isSupported,
      engineUnsupportedReason: engine.isSupported
          ? null
          : engine.unsupportedReason,
    );
  });

  final _details = <String, Loadable<MediaDetails>>{};
  final _search = <String, Loadable<List<MediaItem>>>{};
  final _category = <String, Loadable<List<MediaItem>>>{};
  final _episodes = <String, Loadable<List<Episode>>>{};
  final _catalogItems = <String, Loadable<List<MediaItem>>>{};
  final _discovery = <String, Loadable<IncrementalDiscoveryState>>{};

  final _sourceSearchCache = ExpiringCache<String, List<ProviderResult>>(
    maxEntries: 32,
    ttl: const Duration(minutes: 2),
  );

  String get bridgeVersion => streaming.nativeBuildIdentity;

  Loadable<MediaDetails> detailsFor(MediaRef ref) {
    return _details.putIfAbsent(
      ref.routeKey,
      () => Loadable(() => media.details(ref)),
    );
  }

  Loadable<List<MediaItem>> search(String query) {
    return _search.putIfAbsent(
      query,
      () => Loadable(() => media.search(query)),
    );
  }

  Loadable<List<MediaItem>> category(CategoryRequest request) {
    final key = '${request.type.name}|${request.genreId}|${request.page}';
    return _category.putIfAbsent(key, () {
      return Loadable(() {
        if (request.page == 1 && request.genreId == 0) {
          if (request.type == MediaType.movie) return media.popularMovies();
          return media.trendingSeries();
        }
        return media.discover(
          request.type,
          request.genreId,
          page: request.page,
        );
      });
    });
  }

  Loadable<List<Episode>> episodes(SeasonRequest request) {
    final key = '${request.seriesId}|${request.seasonNumber}';
    return _episodes.putIfAbsent(
      key,
      () => Loadable(
        () => media.episodes(request.seriesId, request.seasonNumber),
      ),
    );
  }

  Loadable<List<MediaItem>> catalogItems(StreamingCatalogRequest request) {
    final key = '${request.type.name}|${request.catalogId}';
    return _catalogItems.putIfAbsent(key, () {
      return Loadable(() {
        if (!AppConfig.hasStreamingCatalogs) return Future.value(const []);
        return catalogs.catalog(request.type, request.catalogId);
      });
    });
  }

  Loadable<IncrementalDiscoveryState> discovery(SourceRequest request) {
    final key =
        '${request.media.routeKey}|${request.season}|${request.episode}';
    return _discovery.putIfAbsent(key, () => _startDiscovery(request));
  }

  Loadable<IncrementalDiscoveryState> _startDiscovery(SourceRequest request) {
    late final Loadable<IncrementalDiscoveryState> loadable;
    final tokens = <CancelToken?>[];
    loadable = Loadable(() async {
      final urls = await addonUrls.future;
      final activePolicy = await policy.future;
      Future<String>? imdb;
      // One unparseable stored URL used to throw out of this list and take the
      // whole search down, so a single bad paste hid every other provider.
      // Skip it here and report it as its own failed lane instead.
      final providers = <TorrentProvider>[
        torrents,
        for (final url in urls)
          if (_validAddonUrl(url) case final manifest?)
            AddonTorrentProvider(
              manifestUrl: manifest,
              resolveImdbId: (mediaRef) => imdb ??= media.imdbId(mediaRef),
            ),
      ];
      final invalidUrls = urls
          .where((url) => _validAddonUrl(url) == null)
          .toList();
      final states = <String, IncrementalProviderState>{
        for (final provider in providers)
          provider.name: IncrementalProviderState(
            name: provider.name,
            status: ProviderStatus.loading,
          ),
        // Surfaced, not swallowed: the settings screen lists these back.
        if (invalidUrls.isNotEmpty)
          'Unusable addon link': IncrementalProviderState(
            name: 'Unusable addon link',
            status: ProviderStatus.error,
            error:
                'Ignored: ${invalidUrls.join(', ')}. '
                'A Stremio addon URL must end in /manifest.json.',
          ),
      };
      loadable.setValue(
        IncrementalDiscoveryState(providers: Map.of(states), isComplete: false),
      );
      await for (final update in searchProvidersIncremental(
        providers,
        request.media,
        seasonNumber: request.season,
        episodeNumber: request.episode,
        cancelTokens: tokens,
      )) {
        final allowed = update.sources.where(activePolicy.allows).toList();
        rankSources(allowed);
        states[update.name] = IncrementalProviderState(
          name: update.name,
          status: update.status,
          sources: allowed,
          error: update.error,
        );
        loadable.setValue(
          IncrementalDiscoveryState(
            providers: Map.of(states),
            isComplete: false,
          ),
        );
      }
      return IncrementalDiscoveryState(
        providers: Map.of(states),
        isComplete: true,
      );
    });
    return loadable;
  }

  Future<List<ProviderResult>> sourceResults(SourceRequest request) async {
    final urls = await addonUrls.future;
    final activePolicy = await policy.future;
    final key =
        '${urls.join(',')}|${request.media.routeKey}|${request.season}|${request.episode}';
    final tokens = <CancelToken?>[];
    return _sourceSearchCache.get(key, () async {
      Future<String>? imdb;
      final providers = <TorrentProvider>[
        torrents,
        for (final url in urls)
          AddonTorrentProvider(
            manifestUrl: AddonTorrentProvider.validateUrl(url),
            resolveImdbId: (mediaRef) => imdb ??= media.imdbId(mediaRef),
          ),
      ];
      final results = await searchAllProviders(
        providers,
        request.media,
        seasonNumber: request.season,
        episodeNumber: request.episode,
        cancelTokens: tokens,
      );
      return _splitAndRank(results, activePolicy);
    });
  }

  Future<HttpServerInfo> httpServerInfo() async {
    final engine = streaming.engine;
    if (engine is HttpServerDiagnosticsProvider) {
      final diagnostics = engine as HttpServerDiagnosticsProvider;
      return diagnostics.httpServerInfo();
    }
    return HttpServerInfo(
      status: HttpServerStatus.unsupported,
      message:
          engine.unsupportedReason ??
          'The built-in HTTP server is unavailable on this platform.',
    );
  }

  void refreshDiscovery(SourceRequest request) {
    final key =
        '${request.media.routeKey}|${request.season}|${request.episode}';
    _sourceSearchCache.invalidateWhere(
      (cacheKey) => cacheKey.contains('|${request.media.routeKey}|'),
    );
    final existing = _discovery[key];
    if (existing != null) unawaited(existing.reload());
  }

  void clearCategories() => _category.clear();

  Future<void> reloadHome() async {
    await Future.wait([
      trendingMovies.reload(),
      trendingSeries.reload(),
      popularMovies.reload(),
      streamingCatalogs.reload(),
      history.reload(),
      myList.reload(),
    ]);
    _search.clear();
    _category.clear();
    _catalogItems.clear();
  }
}

List<ProviderResult> _splitAndRank(
  List<ProviderResult> results,
  SourcePolicy policy,
) {
  final ranked = results.expand((result) {
    final allowed = result.sources.where(policy.allows).toList();
    rankSources(allowed);
    if (result.name != 'torrentio.strem.fun' || result.error != null) {
      return [ProviderResult(result.name, allowed, error: result.error)];
    }
    final names = {
      ...supportedIndexers.values,
      ...allowed.map((source) => source.providerName),
    };
    return names.map(
      (name) => ProviderResult(
        name,
        allowed.where((source) => source.providerName == name).toList(),
      ),
    );
  }).toList();
  for (final lane in ranked) {
    rankSources(lane.sources);
  }
  return ranked;
}

class AddonUrlsController extends ChangeNotifier {
  AddonUrlsController() {
    unawaited(reload());
  }

  List<String>? value;
  Object? error;
  bool loading = true;
  Future<List<String>>? _pending;

  Future<List<String>> get future => _pending ?? reload();

  Future<List<String>> reload() {
    final run = readAddonUrls().then((urls) {
      value = urls;
      loading = false;
      error = null;
      notifyListeners();
      return urls;
    });
    _pending = run;
    return run;
  }

  Future<void> save(List<String> urls) async {
    final validated = urls
        .map(AddonTorrentProvider.validateUrl)
        .map((url) => url.toString())
        .toSet()
        .toList();
    await writeAddonUrls(validated);
    value = validated;
    loading = false;
    notifyListeners();
  }

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(List<String> data) data,
  }) {
    if (this.error != null && value == null) {
      return error(this.error!, StackTrace.current);
    }
    if (this.loading && value == null) return loading();
    return data(value ?? const []);
  }
}

class WatchHistoryController extends ChangeNotifier {
  WatchHistoryController() {
    unawaited(reload());
  }

  List<WatchEntry>? value;
  bool loading = true;
  Future<void> _serial = Future.value();

  Future<List<WatchEntry>> get future async {
    if (value != null) return value!;
    await reload();
    return value ?? const [];
  }

  Future<List<WatchEntry>> reload() async {
    value = await readWatchHistory();
    loading = false;
    notifyListeners();
    return value!;
  }

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<void> save(WatchEntry entry) => _locked(() async {
    final current = value ?? await readWatchHistory();
    final next = normalizeWatchHistory([
      entry.copyWith(updatedAt: DateTime.now()),
      ...current.where((item) => item.key != entry.key),
    ]);
    await writeWatchHistory(next);
    value = next;
    loading = false;
    notifyListeners();
  });

  Future<void> remove(String key) => _locked(() async {
    final current = value ?? await readWatchHistory();
    final next = current.where((item) => item.key != key).toList();
    await writeWatchHistory(next);
    value = next;
    notifyListeners();
  });

  Future<void> clear() => _locked(() async {
    await writeWatchHistory(const []);
    value = const [];
    notifyListeners();
  });

  WatchEntry? entryFor(String key) {
    return value?.where((item) => item.key == key).firstOrNull;
  }

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(List<WatchEntry> data) data,
  }) {
    if (this.loading && value == null) return loading();
    return data(value ?? const []);
  }
}

class MyListController extends ChangeNotifier {
  MyListController() {
    unawaited(reload());
  }

  List<SavedItem>? value;
  bool loading = true;

  Future<List<SavedItem>> reload() async {
    value = await readMyList();
    loading = false;
    notifyListeners();
    return value!;
  }

  Future<bool> toggle(SavedItem item) async {
    final current = value ?? await readMyList();
    if (current.any((entry) => entry.key == item.key)) {
      final next = current.where((entry) => entry.key != item.key).toList();
      await writeMyList(next);
      value = next;
      notifyListeners();
      return false;
    }
    final next = normalizeMyList([
      item.copyWithAddedAt(DateTime.now()),
      ...current,
    ]);
    await writeMyList(next);
    value = next;
    notifyListeners();
    return true;
  }

  Future<void> add(SavedItem item) async {
    final current = value ?? await readMyList();
    final next = normalizeMyList([
      item.copyWithAddedAt(DateTime.now()),
      ...current,
    ]);
    await writeMyList(next);
    value = next;
    notifyListeners();
  }

  Future<void> remove(String key) async {
    final current = value ?? await readMyList();
    final next = current.where((entry) => entry.key != key).toList();
    await writeMyList(next);
    value = next;
    notifyListeners();
  }

  Future<void> clear() async {
    await writeMyList(const []);
    value = const [];
    notifyListeners();
  }

  bool isSaved(MediaRef media) {
    return value?.any((entry) => entry.media == media) ?? false;
  }

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(List<SavedItem> data) data,
  }) {
    if (this.loading && value == null) return loading();
    return data(value ?? const []);
  }
}

class SettingsController extends ChangeNotifier {
  SettingsController() {
    unawaited(reload());
  }

  AppSettings? value;
  bool loading = true;

  Future<AppSettings> get future async {
    if (value != null) return value!;
    return reload();
  }

  Future<AppSettings> reload() async {
    value = await readAppSettings();
    loading = false;
    notifyListeners();
    return value!;
  }

  Future<void> _save(AppSettings settings) async {
    await writeAppSettings(settings);
    value = settings;
    loading = false;
    notifyListeners();
  }

  Future<void> setSubtitleLanguage(String? language) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(preferredSubtitleLanguage: language));
  }

  Future<void> setAudioLanguage(String? language) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(preferredAudioLanguage: language));
  }

  Future<void> setAutoLoadSubtitles(bool enabled) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(autoLoadSubtitles: enabled));
  }

  Future<void> setStreamingCatalogsEnabled(bool enabled) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(streamingCatalogsEnabled: enabled));
  }

  Future<void> setPlayerVolume(double volume) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(playerVolume: volume));
  }

  Future<void> setPlayerRate(double rate) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(playerRate: rate));
  }

  Future<void> setSubtitleTextScale(double scale) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(subtitleTextScale: scale));
  }

  Future<void> setSubtitleBackground(SubtitleBackgroundStyle style) async {
    final current = value ?? await readAppSettings();
    await _save(current.copyWith(subtitleBackground: style));
  }

  R when<R>({
    required R Function() loading,
    required R Function(Object error, StackTrace? stackTrace) error,
    required R Function(AppSettings data) data,
  }) {
    if (this.loading && value == null) return loading();
    return data(value ?? const AppSettings());
  }
}

/// The parsed manifest for [url], or null when it is not a usable addon link.
Uri? _validAddonUrl(String url) {
  try {
    return AddonTorrentProvider.validateUrl(url);
  } catch (_) {
    return null;
  }
}
