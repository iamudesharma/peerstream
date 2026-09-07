import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/media_row.dart';
import '../../core/widgets/section_header.dart';
import '../../providers/app_providers.dart';
import '../../services/tmdb/tmdb_service.dart';
import 'continue_watching_row.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasHistory =
        ref.watch(watchHistoryProvider).value?.isNotEmpty ?? false;
    final hasMyList =
        ref.watch(myListProvider).value?.isNotEmpty ?? false;
    final hasToken = AppConfig.hasTmdbToken;
    return AppScaffold(
      selectedIndex: 0,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(trendingMoviesProvider);
          ref.invalidate(trendingSeriesProvider);
          ref.invalidate(popularMoviesProvider);
          ref.invalidate(streamingCatalogsProvider);
          ref.invalidate(streamingCatalogProvider);
          ref.invalidate(searchResultsProvider);
          ref.invalidate(categoryProvider);
          ref.invalidate(watchHistoryProvider);
          ref.invalidate(myListProvider);
        },
        child: CustomScrollView(
          slivers: [
            _HomeSearchBar(onSearch: () => context.go('/search')),
            if (!hasToken)
              const SliverToBoxAdapter(child: _ConfigurationNotice()),
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
                items: ref.watch(trendingMoviesProvider),
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
                items: ref.watch(trendingSeriesProvider),
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
                items: ref.watch(popularMoviesProvider),
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
              const SliverToBoxAdapter(
                child: MediaRow(
                  title: 'Open movies',
                  items: AsyncData(demoItems),
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
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      floating: true,
      snap: false,
      automaticallyImplyLeading: false,
      backgroundColor: DesignTokens.surface,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: 68,
      flexibleSpace: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: DesignTokens.contentMaxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.pageGutter,
                vertical: DesignTokens.space2,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 560;
                  final field = Expanded(
                    child: GestureDetector(
                      onTap: onSearch,
                      child: AbsorbPointer(
                        child: TextField(
                          readOnly: true,
                          decoration: const InputDecoration(
                            hintText: 'Search movies and series',
                            prefixIcon: Icon(Icons.search),
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: DesignTokens.space3,
                              vertical: DesignTokens.space2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  if (narrow) {
                    return Row(
                      children: [
                        const StatusPill(),
                        const SizedBox(width: DesignTokens.space2),
                        field,
                        const SizedBox(width: DesignTokens.space2),
                        IconButton.filled(
                          tooltip: 'Search',
                          onPressed: onSearch,
                          icon: const Icon(Icons.search),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      const StatusPill(),
                      const SizedBox(width: DesignTokens.space3),
                      field,
                      const SizedBox(width: DesignTokens.space3),
                      FilledButton.icon(
                        onPressed: onSearch,
                        icon: const Icon(Icons.search),
                        label: const Text('Search'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
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
        border: Border.all(
          color: DesignTokens.accent.withValues(alpha: 0.5),
        ),
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

class _MyListSliver extends ConsumerWidget {
  const _MyListSliver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myList = ref.watch(myListProvider);
    return myList.when(
      loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
      error: (_, _) => const SliverToBoxAdapter(child: SizedBox.shrink()),
      data: (list) {
        if (list.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final items = AsyncData(
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
                    await ref.read(myListProvider.notifier).clear();
                  }
                },
          ),
        );
      },
    );
  }
}

class _ConfigurationNotice extends StatelessWidget {
  const _ConfigurationNotice();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        DesignTokens.pageGutter,
        DesignTokens.pageGutter,
        DesignTokens.pageGutter,
        0,
      ),
      padding: const EdgeInsets.all(DesignTokens.space4),
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.warn.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.key_outlined, color: DesignTokens.warn),
          const SizedBox(width: DesignTokens.space3),
          Expanded(
            child: Text(
              'TMDB is not configured. The open movies below still play. '
              'Relaunch with --dart-define=TMDB_READ_TOKEN=your_token to enable discovery and search.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: DesignTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingCatalogs extends ConsumerWidget {
  const _StreamingCatalogs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppConfig.hasStreamingCatalogs) {
      return const SizedBox.shrink();
    }
    final catalogs = ref.watch(streamingCatalogsProvider);
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
                'USA · No API key',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: DesignTokens.space3),
            for (var i = 0; i < rows.length; i++) ...[
              MediaRow(
                title: rows[i].title,
                items: ref.watch(
                  streamingCatalogProvider((
                    type: rows[i].type,
                    catalogId: rows[i].id,
                  )),
                ),
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
                      avatar: Icon(genre.$3, size: 16),
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
