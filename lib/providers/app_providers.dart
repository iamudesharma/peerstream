import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../models/media_details.dart';
import '../models/media_item.dart';
import '../models/saved_item.dart';
import '../models/season.dart';
import '../models/torrent_models.dart';
import '../models/watch_progress.dart';
import '../repositories/media_repository.dart';
import '../services/history/watch_history_store.dart';
import '../services/mylist/my_list_store.dart';
import '../services/streaming/source_ranking.dart';
import '../services/streaming/streaming_service.dart';
import '../services/playback/playback_cache.dart';
import '../services/stremio/stremio_catalog_service.dart';
import '../services/tmdb/tmdb_service.dart';
import '../services/torrent/torrent_engine_factory.dart';
import '../services/torrent/source_policy.dart';
import '../services/torrent/source_policy_loader.dart';
import '../services/torrent/bundled_torrent_api.dart';
import '../services/torrent/torrent_provider.dart';
import '../services/torrent/addon_provider.dart';
import '../services/torrent/addon_settings.dart';
import '../services/torrent/provider_cache.dart';
import '../services/torrent/provider_catalog.dart';
import '../services/torrent/source_discovery.dart';
import '../services/torrent/torrent_engine.dart';
import '../services/subtitles/subtitle_provider.dart';

final tmdbServiceProvider = Provider((ref) => TmdbService());
final stremioCatalogServiceProvider = Provider(
  (ref) => StremioCatalogService(),
);
final mediaRepositoryProvider = Provider(
  (ref) => MediaRepository(
    ref.watch(tmdbServiceProvider),
    AppConfig.hasStreamingCatalogs
        ? ref.watch(stremioCatalogServiceProvider)
        : null,
  ),
);
final addonSubtitleProvider = Provider<AddonSubtitleProvider>(
  (ref) => AddonSubtitleProvider(
    resolveImdbId: ref.read(mediaRepositoryProvider).imdbId,
  ),
);
final bundledTorrentApiProvider = Provider<BundledLegalTorrentApi>(
  (ref) => const BundledLegalTorrentApi(),
);
final torrentProvider = Provider<TorrentProvider>(
  (ref) =>
      WebTorrentLegalDemoProvider(api: ref.watch(bundledTorrentApiProvider)),
);
final sourcePolicyProvider = FutureProvider<SourcePolicy>(
  (ref) => loadSourcePolicy(),
);
final playbackCacheProvider = Provider<PlaybackCacheStore>(
  (ref) => PlaybackCacheStore(),
);
final playbackCacheSummaryProvider = FutureProvider(
  (ref) => ref.watch(playbackCacheProvider).summary(),
);
final playbackCacheEntriesProvider = FutureProvider(
  (ref) => ref.watch(playbackCacheProvider).entries(),
);
final streamingServiceProvider = Provider<StreamingService>((ref) {
  final service = StreamingService(
    createTorrentEngine(),
    ref.watch(playbackCacheProvider),
  );
  ref.onDispose(service.dispose);
  unawaited(service.warmUp());
  return service;
});

/// Runtime native bridge identity. Confirms all platforms ship the same
/// native implementation before comparing performance.
final bridgeVersionProvider = Provider<String>((ref) {
  final service = ref.watch(streamingServiceProvider);
  return service.nativeBuildIdentity;
});

/// Focused playback-phase subscription. Widgets that only need the phase
/// (loading vs playing vs error) watch this instead of the full
/// [streamingStateProvider], avoiding rebuilds on every stats tick.
final playbackPhaseProvider = StreamProvider<StreamingPhase>((ref) {
  final service = ref.watch(streamingServiceProvider);
  return (() async* {
    yield service.state.phase;
    await for (final s in service.states) {
      yield s.phase;
    }
  })();
});

/// Focused stats subscription for the statistics strip.
final playbackStatsProvider = StreamProvider<TorrentStats>((ref) {
  final service = ref.watch(streamingServiceProvider);
  return (() async* {
    yield service.state.stats;
    await for (final s in service.states) {
      yield s.stats;
    }
  })();
});

final trendingMoviesProvider = FutureProvider<List<MediaItem>>(
  (ref) => ref.watch(mediaRepositoryProvider).trendingMovies(),
);
final trendingSeriesProvider = FutureProvider<List<MediaItem>>(
  (ref) => ref.watch(mediaRepositoryProvider).trendingSeries(),
);
final popularMoviesProvider = FutureProvider<List<MediaItem>>(
  (ref) => ref.watch(mediaRepositoryProvider).popularMovies(),
);
// Bounded browsing memory: details/search/category families auto-dispose
// when the UI leaves, cancelling their underlying requests. A short-lived
// expiring cache in the repository layer (see StremioCatalogService/Tmdb)
// keeps back-navigation instant without retaining every query forever.
final detailsProvider =
    FutureProvider.autoDispose.family<MediaDetails, MediaRef>(
      (ref, mediaRef) => ref.watch(mediaRepositoryProvider).details(mediaRef),
    );

/// Streaming Catalogs rows (USA default, public BeamUp instance, no API key).
final streamingCatalogsProvider = FutureProvider<List<StremioCatalog>>((ref) {
  if (!AppConfig.hasStreamingCatalogs) return const [];
  return ref.watch(stremioCatalogServiceProvider).catalogs();
});

typedef StreamingCatalogRequest = ({MediaType type, String catalogId});

final streamingCatalogProvider =
    FutureProvider.autoDispose.family<List<MediaItem>, StreamingCatalogRequest>((
      ref,
      request,
    ) {
      if (!AppConfig.hasStreamingCatalogs) return const [];
      return ref
          .watch(stremioCatalogServiceProvider)
          .catalog(request.type, request.catalogId);
    });

class AddonUrls extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async => readAddonUrls();
  Future<void> save(List<String> urls) async {
    final validated = urls
        .map(AddonTorrentProvider.validateUrl)
        .map((u) => u.toString())
        .toSet()
        .toList();
    await writeAddonUrls(validated);
    state = AsyncData(validated);
  }
}

final addonUrlsProvider = AsyncNotifierProvider<AddonUrls, List<String>>(
  AddonUrls.new,
);

class WatchHistory extends AsyncNotifier<List<WatchEntry>> {
  // Serializes concurrent saves so position/duration races cannot interleave
  // writes and lose the latest resume point.
  Future<void> _serial = Future.value();

  @override
  Future<List<WatchEntry>> build() => readWatchHistory();

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<void> save(WatchEntry entry) => _locked(() async {
    final current = state.value ?? await readWatchHistory();
    final next = normalizeWatchHistory([
      entry.copyWith(updatedAt: DateTime.now()),
      ...current.where((item) => item.key != entry.key),
    ]);
    await writeWatchHistory(next);
    state = AsyncData(next);
  });

  Future<void> remove(String key) => _locked(() async {
    final current = state.value ?? await readWatchHistory();
    final next = current.where((item) => item.key != key).toList();
    await writeWatchHistory(next);
    state = AsyncData(next);
  });

  Future<void> clear() => _locked(() async {
    await writeWatchHistory(const []);
    state = const AsyncData([]);
  });

  WatchEntry? entryFor(String key) {
    return state.value?.where((item) => item.key == key).firstOrNull;
  }
}

final watchHistoryProvider =
    AsyncNotifierProvider<WatchHistory, List<WatchEntry>>(WatchHistory.new);

class MyList extends AsyncNotifier<List<SavedItem>> {
  @override
  Future<List<SavedItem>> build() => readMyList();

  Future<bool> toggle(SavedItem item) async {
    final current = state.value ?? await readMyList();
    if (current.any((entry) => entry.key == item.key)) {
      final next = current.where((entry) => entry.key != item.key).toList();
      await writeMyList(next);
      state = AsyncData(next);
      return false;
    }
    final next = normalizeMyList([
      item.copyWithAddedAt(DateTime.now()),
      ...current,
    ]);
    await writeMyList(next);
    state = AsyncData(next);
    return true;
  }

  Future<void> add(SavedItem item) async {
    final current = state.value ?? await readMyList();
    final next = normalizeMyList([
      item.copyWithAddedAt(DateTime.now()),
      ...current,
    ]);
    await writeMyList(next);
    state = AsyncData(next);
  }

  Future<void> remove(String key) async {
    final current = state.value ?? await readMyList();
    final next = current.where((entry) => entry.key != key).toList();
    await writeMyList(next);
    state = AsyncData(next);
  }

  Future<void> clear() async {
    await writeMyList(const []);
    state = const AsyncData([]);
  }

  bool isSaved(MediaRef media) {
    return state.value?.any((entry) => entry.media == media) ?? false;
  }
}

final myListProvider = AsyncNotifierProvider<MyList, List<SavedItem>>(
  MyList.new,
);
typedef SourceRequest = ({MediaRef media, int? season, int? episode});

String _sourceCacheKey(SourceRequest request) =>
    '${request.media.routeKey}|${request.season}|${request.episode}';

/// Bounded, expiring source-search cache (2-minute TTL, 32 entries) with
/// request deduplication. Back-navigation and player retry reuse the last
/// result without hammering addons; changing the query naturally misses.
final _sourceSearchCache =
    ExpiringCache<String, List<ProviderResult>>(
      maxEntries: 32,
      ttl: const Duration(minutes: 2),
    );

List<ProviderResult> _splitAndRank(
  List<ProviderResult> results,
  SourcePolicy policy,
) {
  final ranked = results.expand((r) {
    final allowed = r.sources.where(policy.allows).toList();
    rankSources(allowed);
    if (r.name != 'torrentio.strem.fun' || r.error != null) {
      return [ProviderResult(r.name, allowed, error: r.error)];
    }
    final names = {...supportedIndexers.values, ...allowed.map((s) => s.providerName)};
    return names.map(
      (name) => ProviderResult(
        name,
        allowed.where((s) => s.providerName == name).toList(),
      ),
    );
  }).toList();
  // Rank sources within each lane for instant-start ordering.
  for (final lane in ranked) {
    rankSources(lane.sources);
  }
  return ranked;
}

/// Incremental discovery: emits per-provider loading → ready/error states as
/// each provider completes, instead of holding fast sources behind the
/// slowest 20s timeout. The UI shows usable sources sooner; cancellation is
/// wired to provider disposal.
final sourceDiscoveryProvider =
    StreamProvider.autoDispose.family<IncrementalDiscoveryState, SourceRequest>((
      ref,
      request,
    ) async* {
      final urls = await ref.watch(addonUrlsProvider.future);
      final policy = await ref.watch(sourcePolicyProvider.future);
      final repository = ref.watch(mediaRepositoryProvider);
      Future<String>? imdb;
      final providers = <TorrentProvider>[
        ref.watch(torrentProvider),
        for (final url in urls)
          AddonTorrentProvider(
            manifestUrl: AddonTorrentProvider.validateUrl(url),
            resolveImdbId: (media) => imdb ??= repository.imdbId(media),
          ),
      ];
      final cancelTokens = <CancelToken?>[];
      ref.onDispose(() {
        for (final t in cancelTokens) {
          try {
            t?.cancel('disposed');
          } catch (_) {}
        }
      });
      final states = <String, IncrementalProviderState>{
        for (final p in providers)
          p.name: IncrementalProviderState(
            name: p.name,
            status: ProviderStatus.loading,
          ),
      };
      yield IncrementalDiscoveryState(
        providers: Map.of(states),
        isComplete: false,
      );
      await for (final update in searchProvidersIncremental(
        providers,
        request.media,
        seasonNumber: request.season,
        episodeNumber: request.episode,
        cancelTokens: cancelTokens,
      )) {
        final allowed = update.sources.where(policy.allows).toList();
        rankSources(allowed);
        states[update.name] = IncrementalProviderState(
          name: update.name,
          status: update.status,
          sources: allowed,
          error: update.error,
        );
        yield IncrementalDiscoveryState(
          providers: Map.of(states),
          isComplete: false,
        );
      }
      yield IncrementalDiscoveryState(
        providers: Map.of(states),
        isComplete: true,
      );
    });

final sourceResultsProvider =
    FutureProvider.autoDispose.family<List<ProviderResult>, SourceRequest>((
      ref,
      request,
    ) async {
      final urls = await ref.watch(addonUrlsProvider.future);
      final policy = await ref.watch(sourcePolicyProvider.future);
      final repository = ref.watch(mediaRepositoryProvider);
      final bundled = ref.watch(torrentProvider);
      final key = '${urls.join(',')}|${_sourceCacheKey(request)}';
      // Keep the future alive briefly for back-navigation without pinning
      // every query forever.
      final keepAlive = ref.keepAlive();
      Timer(const Duration(minutes: 2), keepAlive.close);
      final cancelTokens = <CancelToken?>[];
      ref.onDispose(() {
        for (final t in cancelTokens) {
          try {
            t?.cancel('disposed');
          } catch (_) {}
        }
      });
      return _sourceSearchCache.get(key, () async {
        Future<String>? imdb;
        final providers = <TorrentProvider>[
          bundled,
          for (final url in urls)
            AddonTorrentProvider(
              manifestUrl: AddonTorrentProvider.validateUrl(url),
              resolveImdbId: (media) => imdb ??= repository.imdbId(media),
            ),
        ];
        final results = await searchAllProviders(
          providers,
          request.media,
          seasonNumber: request.season,
          episodeNumber: request.episode,
          cancelTokens: cancelTokens,
        );
        return _splitAndRank(results, policy);
      });
    });

final sourceListProvider =
    FutureProvider.autoDispose.family<List<TorrentSource>, MediaRef>((
      ref,
      media,
    ) async => (await ref.watch(
      sourceResultsProvider((media: media, season: null, episode: null)).future,
    )).expand((r) => r.sources).toList());

final searchResultsProvider =
    FutureProvider.autoDispose.family<List<MediaItem>, String>(
      (ref, query) => ref.watch(mediaRepositoryProvider).search(query),
    );

typedef CategoryRequest = ({MediaType type, int genreId, int page});
final categoryProvider =
    FutureProvider.autoDispose.family<List<MediaItem>, CategoryRequest>((
      ref,
      request,
    ) {
      final repo = ref.watch(mediaRepositoryProvider);
      if (request.page == 1 && request.genreId == 0) {
        if (request.type == MediaType.movie) return repo.popularMovies();
        return repo.trendingSeries();
      }
      return repo.discover(request.type, request.genreId, page: request.page);
    });

typedef SeasonRequest = ({int seriesId, int seasonNumber});
final episodeListProvider =
    FutureProvider.autoDispose.family<List<Episode>, SeasonRequest>(
      (ref, request) => ref
          .watch(mediaRepositoryProvider)
          .episodes(request.seriesId, request.seasonNumber),
    );

final streamingStateProvider = StreamProvider<StreamingState>((ref) {
  final service = ref.watch(streamingServiceProvider);
  return (() async* {
    yield service.state;
    yield* service.states;
  })();
});

/// Engine diagnostics for the player diagnostics strip.
final engineDiagnosticsProvider = FutureProvider<EngineDiagnostics?>((ref) async {
  final service = ref.watch(streamingServiceProvider);
  final engine = service.engine;
  if (engine is EngineDiagnosticsProvider) {
    try {
      return await (engine as EngineDiagnosticsProvider).engineDiagnostics();
    } catch (_) {
      return null;
    }
  }
  return null;
});
