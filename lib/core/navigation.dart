import 'package:dartnative/dartnative.dart';

import '../features/details/details_screen.dart';
import '../features/home/category_screen.dart';
import '../features/home/home_screen.dart';
import '../features/player/player_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/addons_screen.dart';
import '../features/settings/playback_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/subtitles_screen.dart';
import '../features/sources/source_selection_screen.dart';
import '../models/media_item.dart';
import '../models/torrent_models.dart';

/// Selected root tab. Home, search, and settings stay on the permanent root
/// so back does not walk through destinations.
final shellIndex = signal<int>(0);

void registerPeerStreamRoutes() {
  registerRoutes({
    '/': (_) => const HomeScreen(),
    '/search': (_) => const SearchScreen(),
    '/settings': (_) => const SettingsScreen(),
    '/settings/addons': (_) => const AddonsScreen(),
    '/settings/playback': (_) => const PlaybackScreen(),
    '/settings/subtitles': (_) => const SubtitlesScreen(),
    '/settings/about': (_) => const AboutScreen(),
    '/details': (_) => const _RouteNeedsArguments(name: 'Details'),
    '/category': (_) => const _RouteNeedsArguments(name: 'Category'),
    '/sources': (_) => const _RouteNeedsArguments(name: 'Sources'),
    '/player': (_) => const _RouteNeedsArguments(name: 'Player'),
  });
}

extension PeerStreamNav on BuildContext {
  void go(String location) => openLocation(this, location, popToRoot: true);

  Future<T?> push<T>(String location, {Object? extra}) {
    return openLocation(this, location, extra: extra);
  }

  void pop<T extends Object?>([T? result]) => Navigator.pop(this, result);
}

Future<T?> openLocation<T>(
  BuildContext context,
  String location, {
  Object? extra,
  bool popToRoot = false,
}) {
  final uri = Uri.parse(location);
  final path = uri.path;
  if (path == '/' || path.isEmpty) {
    shellIndex.value = 0;
    _popToRoot(context);
    return Future.value();
  }
  if (path == '/search') {
    shellIndex.value = 1;
    _popToRoot(context);
    return Future.value();
  }
  if (path == '/settings') {
    shellIndex.value = 2;
    _popToRoot(context);
    return Future.value();
  }
  if (path == '/storage') {
    return _push<T>(context, '/settings/playback', const PlaybackScreen());
  }
  if (path == '/settings/addons') {
    return _push<T>(context, path, const AddonsScreen());
  }
  if (path == '/settings/playback') {
    return _push<T>(context, path, const PlaybackScreen());
  }
  if (path == '/settings/subtitles') {
    return _push<T>(context, path, const SubtitlesScreen());
  }
  if (path == '/settings/about') {
    return _push<T>(context, path, const AboutScreen());
  }

  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isNotEmpty && parts.first == 'details' && parts.length >= 3) {
    return _push<T>(
      context,
      '/details',
      DetailsScreen(
        mediaRef: MediaRef(
          id: int.parse(parts[2]),
          type: MediaType.parse(parts[1]),
        ),
      ),
    );
  }
  if (parts.isNotEmpty && parts.first == 'category' && parts.length >= 3) {
    final genreId = int.parse(parts[2]);
    return _push<T>(
      context,
      '/category',
      CategoryScreen(
        type: MediaType.parse(parts[1]),
        genreId: genreId,
        title: uri.queryParameters['title'] ?? 'Category',
      ),
    );
  }
  if (parts.isNotEmpty && parts.first == 'sources' && parts.length >= 3) {
    return _push<T>(
      context,
      '/sources',
      SourceSelectionScreen(
        season: int.tryParse(uri.queryParameters['season'] ?? ''),
        episode: int.tryParse(uri.queryParameters['episode'] ?? ''),
        mediaRef: MediaRef(
          id: int.parse(parts[2]),
          type: MediaType.parse(parts[1]),
        ),
      ),
    );
  }
  if (parts.isNotEmpty && parts.first == 'player' && parts.length >= 3) {
    final source = extra is TorrentSource ? extra : null;
    return _push<T>(
      context,
      '/player',
      PlayerScreen(
        season: int.tryParse(uri.queryParameters['season'] ?? ''),
        episode: int.tryParse(uri.queryParameters['episode'] ?? ''),
        resumeMs: int.tryParse(uri.queryParameters['resume'] ?? ''),
        sourceId: uri.queryParameters['source'] ?? source?.id ?? '',
        mediaRef: MediaRef(
          id: int.parse(parts[2]),
          type: MediaType.parse(parts[1]),
        ),
        initialSource: source,
      ),
    );
  }
  return Future.value();
}

Future<T?> _push<T>(BuildContext context, String name, Widget screen) {
  return Navigator.push<T>(
    context,
    PageRoute<T>(
      settings: name,
      builder: (_) => screen,
    ),
  );
}

void _popToRoot(BuildContext context) {
  if (Navigator.of(context).canPop()) {
    Navigator.popUntil(context, (route) => route.isFirst);
  }
}

class _RouteNeedsArguments extends StatelessWidget {
  const _RouteNeedsArguments({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: const Center(
        child: Text('Open this screen from the catalogue.'),
      ),
    );
  }
}
