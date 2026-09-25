import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'core/widgets/app_empty.dart';
import 'features/details/details_screen.dart';
import 'features/home/category_screen.dart';
import 'features/home/home_screen.dart';
import 'features/player/player_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/about_screen.dart';
import 'features/settings/addons_screen.dart';
import 'features/settings/playback_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/subtitles_screen.dart';
import 'features/sources/source_selection_screen.dart';
import 'models/media_item.dart';
import 'models/torrent_models.dart';
import 'providers/app_providers.dart';

const _genreNames = <int, String>{
  28: 'Action',
  35: 'Comedy',
  16: 'Animation',
  99: 'Documentary',
  878: 'Science fiction',
};

MediaType _mediaTypeOrThrow(String? value) {
  if (value == 'movie') return MediaType.movie;
  if (value == 'tv') return MediaType.tv;
  throw const FormatException('Unknown media type');
}

int _idOrThrow(String? value) {
  final id = int.tryParse(value ?? '');
  if (id == null) throw const FormatException('Invalid id');
  return id;
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    errorBuilder: (_, state) => _NotFound(path: state.uri.toString()),
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: 'addons',
            builder: (_, _) => const AddonsScreen(),
          ),
          GoRoute(
            path: 'playback',
            builder: (_, _) => const PlaybackScreen(),
          ),
          GoRoute(
            path: 'subtitles',
            builder: (_, _) => const SubtitlesScreen(),
          ),
          GoRoute(
            path: 'about',
            builder: (_, _) => const AboutScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/storage',
        redirect: (_, _) => '/settings/playback',
      ),
      GoRoute(
        path: '/category/:type/:genre',
        builder: (_, state) {
          final type = _mediaTypeOrThrow(state.pathParameters['type']);
          final genreId = _idOrThrow(state.pathParameters['genre']);
          final title =
              state.uri.queryParameters['title'] ??
              _genreNames[genreId] ??
              'Category';
          return CategoryScreen(type: type, genreId: genreId, title: title);
        },
      ),
      GoRoute(
        path: '/details/:type/:id',
        builder: (_, state) => DetailsScreen(
          mediaRef: MediaRef(
            id: _idOrThrow(state.pathParameters['id']),
            type: _mediaTypeOrThrow(state.pathParameters['type']),
          ),
        ),
      ),
      GoRoute(
        path: '/sources/:type/:id',
        builder: (_, state) => SourceSelectionScreen(
          season: int.tryParse(state.uri.queryParameters['season'] ?? ''),
          episode: int.tryParse(state.uri.queryParameters['episode'] ?? ''),
          mediaRef: MediaRef(
            id: _idOrThrow(state.pathParameters['id']),
            type: _mediaTypeOrThrow(state.pathParameters['type']),
          ),
        ),
      ),
      GoRoute(
        path: '/player/:type/:id',
        builder: (_, state) {
          final extra = state.extra;
          return PlayerScreen(
            season: int.tryParse(state.uri.queryParameters['season'] ?? ''),
            episode: int.tryParse(state.uri.queryParameters['episode'] ?? ''),
            mediaRef: MediaRef(
              id: _idOrThrow(state.pathParameters['id']),
              type: _mediaTypeOrThrow(state.pathParameters['type']),
            ),
            sourceId: state.uri.queryParameters['source'] ?? '',
            resumeMs: int.tryParse(state.uri.queryParameters['resume'] ?? ''),
            initialSource: extra is TorrentSource ? extra : null,
          );
        },
      ),
    ],
  );
});

class _NotFound extends StatelessWidget {
  const _NotFound({this.path});
  final String? path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: AppEmpty(
        icon: Icons.explore_off_outlined,
        title: 'Page not found',
        hint: path == null
            ? 'The link you followed does not match a screen.'
            : 'No screen matches "$path".',
        action: FilledButton.icon(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.home_outlined),
          label: const Text('Go home'),
        ),
      ),
    );
  }
}

class PeerStreamApp extends ConsumerStatefulWidget {
  const PeerStreamApp({super.key});

  @override
  ConsumerState<PeerStreamApp> createState() => _PeerStreamAppState();
}

class _PeerStreamAppState extends ConsumerState<PeerStreamApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Durable playback state: hand the DHT routing table and fast-resume
    // data to disk when the app backgrounds or exits. Desktop exit can be
    // deferred briefly so the writes complete before the process dies.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await ref.read(streamingServiceProvider).persistState();
          // Session state writes are synchronous, but fast-resume writes
          // complete on the native alert thread; give them a brief grace
          // period so the process does not exit mid-write.
          await Future<void>.delayed(const Duration(milliseconds: 350));
        } catch (_) {}
        return AppExitResponse.exit;
      },
      onStateChange: (state) {
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          unawaited(ref.read(streamingServiceProvider).persistState());
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'PeerStream',
      debugShowCheckedModeBanner: false,
      theme: buildPeerStreamTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
