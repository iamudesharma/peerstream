import 'package:peerstream/providers/app_store.dart';
import 'package:peerstream/providers/loadable.dart';
import 'package:peerstream/core/navigation.dart';
import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/media_row.dart';
import '../../core/widgets/section_header.dart';
import '../../services/tmdb/tmdb_service.dart';
import 'continue_watching_row.dart';
import 'featured_media.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final hasHistory =
        (AppStore.instance.history..watch(context)).value?.isNotEmpty ?? false;
    final hasMyList =
        (AppStore.instance.myList..watch(context)).value?.isNotEmpty ?? false;
    final hasToken = AppConfig.hasTmdbToken;
    final featured =
        (AppStore.instance.trendingMovies..watch(context)).value?.firstOrNull ??
        demoItems.first;
    return AppScaffold(
      selectedIndex: 0,
      body: RefreshIndicator(
        onRefresh: () => AppStore.instance.reloadHome(),
        child: CustomScrollView(
          slivers: [
            _HomeSearchBar(onSearch: () => context.go('/search')),
            SliverToBoxAdapter(child: FeaturedMedia(item: featured)),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            const SliverToBoxAdapter(child: ContinueWatchingRow()),
            if (hasHistory)
              const SliverToBoxAdapter(
                child: SizedBox(height: DesignTokens.space6),
              ),
            const _MyListSliver(),
            if (hasMyList)
              const SliverToBoxAdapter(
                child: SizedBox(height: DesignTokens.space6),
              ),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Trending movies',
                items: (AppStore.instance.trendingMovies..watch(context)),
                onSeeAll: hasToken
                    ? () => context.push(
                        '/category/movie/0?title=${Uri.encodeComponent('Trending movies')}',
                      )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Trending series',
                items: (AppStore.instance.trendingSeries..watch(context)),
                onSeeAll: hasToken
                    ? () => context.push(
                        '/category/tv/0?title=${Uri.encodeComponent('Trending series')}',
                      )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Popular movies',
                items: (AppStore.instance.popularMovies..watch(context)),
                onSeeAll: hasToken
                    ? () => context.push(
                        '/category/movie/0?title=${Uri.encodeComponent('Popular movies')}',
                      )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            const SliverToBoxAdapter(child: _StreamingCatalogs()),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            const SliverToBoxAdapter(child: _Categories()),
            const SliverToBoxAdapter(
              child: SizedBox(height: DesignTokens.space6),
            ),
            if (!hasToken)
              SliverToBoxAdapter(
                child: MediaRow(
                  title: 'Open movies',
                  items: Loadable.seed(demoItems),
                  demoBadge: true,
                ),
              ),
            if (!hasToken)
              const SliverToBoxAdapter(
                child: SizedBox(height: DesignTokens.space6),
              ),
            const SliverToBoxAdapter(child: _TmdbCredit()),
          ],
        ),
      ),
    );
  }
}

class _HomeSearchBar extends StatelessWidget {
  const _HomeSearchBar({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Discover',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Find your next great watch.',
                    style: TextStyle(color: DesignTokens.textSecondary),
                  ),
                ],
              ),
            ),
            if (constraints.maxWidth >= 600)
              SizedBox(
                width: 300,
                child: OutlinedButton.icon(
                  onPressed: onSearch,
                  icon: const Icon(Icons.search, size: 20),
                  label: const Text('Search movies and series'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: DesignTokens.accentDim,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DesignTokens.accent.withValues(alpha: 0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: DesignTokens.accent),
          SizedBox(width: 6),
          Text(
            'PeerStream',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: DesignTokens.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _MyListSliver extends StatelessWidget {
  const _MyListSliver();

  @override
  Widget build(BuildContext context) {
    final myList = (AppStore.instance.myList..watch(context));
    return myList.when(
      loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
      error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
      data: (list) {
        if (list.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final items = Loadable.seed(
          list.map((entry) => entry.toMediaItem()).toList(),
        );
        return SliverToBoxAdapter(
          child: MediaRow(
            title: 'My List',
            items: items,
            seeAllLabel: 'Clear',
            onSeeAll: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear My List?'),
                  content: const Text(
                    'This removes every saved title from this device.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Keep'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await AppStore.instance.myList.clear();
              }
            },
          ),
        );
      },
    );
  }
}

class _StreamingCatalogs extends StatelessWidget {
  const _StreamingCatalogs();

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasStreamingCatalogs) {
      return const SizedBox.shrink();
    }
    final catalogs = (AppStore.instance.streamingCatalogs..watch(context));
    return catalogs.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader(title: 'Streaming catalogs'),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.pageGutter,
              ),
              child: Text(
                'Explore collections from your streaming services',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: DesignTokens.textTertiary),
              ),
            ),
            const SizedBox(height: DesignTokens.space3),
            for (var i = 0; i < rows.length; i++) ...[
              MediaRow(
                title: rows[i].title,
                items: (AppStore.instance.catalogItems((
                  type: rows[i].type,
                  catalogId: rows[i].id,
                ))..watch(context)),
              ),
              if (i != rows.length - 1)
                const SizedBox(height: DesignTokens.space6),
            ],
          ],
        );
      },
    );
  }
}

class _TmdbCredit extends StatelessWidget {
  const _TmdbCredit();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(DesignTokens.space6),
      child: Text(
        'This product uses the TMDB API but is not endorsed or certified by TMDB.',
        textAlign: TextAlign.center,
        style: TextStyle(color: DesignTokens.textTertiary, fontSize: 12),
      ),
    );
  }
}

class _Categories extends StatelessWidget {
  const _Categories();
  static const genres = [
    ('Action', 28, Icons.bolt),
    ('Comedy', 35, Icons.sentiment_satisfied_alt_outlined),
    ('Documentary', 99, Icons.public),
    ('Animation', 16, Icons.animation),
    ('Science fiction', 878, Icons.rocket_launch_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = AppConfig.hasTmdbToken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'Browse by genre'),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.pageGutter,
          ),
          child: Text(
            enabled
                ? 'Five lanes from the TMDB catalogue.'
                : 'Genre browsing needs a TMDB token.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: DesignTokens.space3),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.pageGutter,
          ),
          child: Wrap(
            spacing: DesignTokens.space2,
            runSpacing: DesignTokens.space2,
            children: genres
                .map(
                  (genre) => Tooltip(
                    message: enabled
                        ? 'Show ${genre.$1} movies'
                        : 'Add a TMDB token to browse ${genre.$1}',
                    child: ActionChip(
                      label: Text(genre.$1),
                      onPressed: enabled
                          ? () => context.push(
                              '/category/movie/${genre.$2}?title=${Uri.encodeComponent(genre.$1)}',
                            )
                          : null,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}
