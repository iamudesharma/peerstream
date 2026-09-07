import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import 'torrent_provider.dart';

/// Per-provider incremental status for source discovery.
///
/// Unlike `Future.wait`, which hides fast providers behind the slowest,
/// incremental discovery publishes each provider's result immediately while
/// retaining individual loading/error states for the UI.
enum ProviderStatus { loading, ready, error }

class IncrementalProviderState {
  const IncrementalProviderState({
    required this.name,
    required this.status,
    this.sources = const [],
    this.error,
  });

  final String name;
  final ProviderStatus status;
  final List<TorrentSource> sources;
  final String? error;

  IncrementalProviderState copyWith({
    ProviderStatus? status,
    List<TorrentSource>? sources,
    String? error,
  }) => IncrementalProviderState(
    name: name,
    status: status ?? this.status,
    sources: sources ?? this.sources,
    error: error ?? this.error,
  );
}

class IncrementalDiscoveryState {
  const IncrementalDiscoveryState({
    this.providers = const {},
    this.isComplete = false,
  });

  final Map<String, IncrementalProviderState> providers;
  final bool isComplete;

  List<TorrentSource> get allSources =>
      providers.values.expand((p) => p.sources).toList();

  bool get hasUsableSource => allSources.isNotEmpty;

  IncrementalDiscoveryState copyWith({
    Map<String, IncrementalProviderState>? providers,
    bool? isComplete,
  }) => IncrementalDiscoveryState(
    providers: providers ?? this.providers,
    isComplete: isComplete ?? this.isComplete,
  );
}

/// Streams one [IncrementalProviderState] per provider as it completes.
///
/// Each provider runs concurrently with its own [CancelToken] so leaving
/// the screen or changing the query cancels the underlying network
/// activity — a bare `Future.timeout` alone does not cancel Dio work.
Stream<IncrementalProviderState> searchProvidersIncremental(
  List<TorrentProvider> providers,
  MediaRef content, {
  int? seasonNumber,
  int? episodeNumber,
  Duration timeout = const Duration(seconds: 20),
  List<CancelToken?>? cancelTokens,
}) async* {
  final controller = StreamController<IncrementalProviderState>();
  var pending = providers.length;
  if (pending == 0) {
    return;
  }
  for (var i = 0; i < providers.length; i++) {
    final provider = providers[i];
    final token = CancelToken();
    if (cancelTokens != null) {
      if (i < cancelTokens.length) {
        cancelTokens[i] = token;
      } else {
        cancelTokens.add(token);
      }
    }
    unawaited(
      provider
          .findSources(
            content,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            cancelToken: token,
          )
          .timeout(timeout)
          .then((sources) {
            final seen = <String>{};
            final deduped = sources
                .where(
                  (s) =>
                      s.content == content &&
                      s.seasonNumber == seasonNumber &&
                      s.episodeNumber == episodeNumber &&
                      seen.add(s.id),
                )
                .toList();
            if (!controller.isClosed) {
              controller.add(
                IncrementalProviderState(
                  name: provider.name,
                  status: ProviderStatus.ready,
                  sources: deduped,
                ),
              );
            }
          })
          .catchError((Object error) {
            if (!controller.isClosed) {
              controller.add(
                IncrementalProviderState(
                  name: provider.name,
                  status: ProviderStatus.error,
                  error: _friendlyProviderError(error),
                ),
              );
            }
          })
          .whenComplete(() {
            pending--;
            if (pending <= 0 && !controller.isClosed) {
              unawaited(controller.close());
            }
          }),
    );
  }
  yield* controller.stream;
}

String _friendlyProviderError(Object error) {
  if (error is DioException) {
    if (error.type == DioExceptionType.cancel) {
      return 'Search was cancelled.';
    }
    return error.response == null
        ? 'Connection failed or timed out. Check the addon URL and connection.'
        : 'Provider returned HTTP ${error.response?.statusCode}.';
  }
  if (error is TimeoutException) {
    return 'Provider timed out. Other providers may still return.';
  }
  return 'Source lookup failed. Check the addon configuration and title ID.';
}
