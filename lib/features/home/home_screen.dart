import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/media_row.dart';
import '../../providers/app_providers.dart';
import '../../services/tmdb/tmdb_service.dart';
import 'continue_watching_row.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppScaffold(
      selectedIndex: 0,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(trendingMoviesProvider);
          ref.invalidate(trendingSeriesProvider);
          ref.invalidate(popularMoviesProvider);
          ref.invalidate(searchResultsProvider);
          ref.invalidate(categoryProvider);
          ref.invalidate(watchHistoryProvider);
          ref.invalidate(myListProvider);
        },
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _CommandHeader(onSearch: () => context.go('/search')),
            ),
            if (!AppConfig.hasTmdbToken)
              const SliverToBoxAdapter(child: _ConfigurationNotice()),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            const SliverToBoxAdapter(child: ContinueWatchingRow()),
            const _MyListSliver(),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            const SliverToBoxAdapter(child: _Categories()),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            const SliverToBoxAdapter(
              child: MediaRow(
                title: 'Open movies',
                items: AsyncData(demoItems),
                demoBadge: true,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Trending movies',
                items: ref.watch(trendingMoviesProvider),
                onSeeAll: AppConfig.hasTmdbToken
                    ? () => context.push(
                          '/category/movie/0?title=${Uri.encodeComponent('Trending movies')}',
                        )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Trending series',
                items: ref.watch(trendingSeriesProvider),
                onSeeAll: AppConfig.hasTmdbToken
                    ? () => context.push(
                          '/category/tv/0?title=${Uri.encodeComponent('Trending series')}',
                        )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: MediaRow(
                title: 'Popular movies',
                items: ref.watch(popularMoviesProvider),
                onSeeAll: AppConfig.hasTmdbToken
                    ? () => context.push(
                          '/category/movie/0?title=${Uri.encodeComponent('Popular movies')}',
                        )
                    : null,
              ),
            ),
            const SliverToBoxAdapter(child: _TmdbCredit()),
          ],
        ),
      ),
    );
  }
}

class _CommandHeader extends StatelessWidget {
  const _CommandHeader({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: DesignTokens.surface,
        border: Border(bottom: BorderSide(color: DesignTokens.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        DesignTokens.pageGutter,
        28,
        DesignTokens.pageGutter,
        24,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DesignTokens.contentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  StatusPill(),
                  SizedBox(width: 8),
                  Text(
                    'Legal peer-to-peer streaming',
                    style: TextStyle(
                      color: DesignTokens.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Find something to watch',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Browse the catalogue, pick an episode or film, then compare sources before you play.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 560;
                  final field = TextField(
                    readOnly: true,
                    onTap: onSearch,
                    decoration: const InputDecoration(
                      hintText: 'Search movies and series',
                      prefixIcon: Icon(Icons.search),
                    ),
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        field,
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: onSearch,
                          icon: const Icon(Icons.search),
                          label: const Text('Search'),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: field),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: onSearch,
                        icon: const Icon(Icons.search),
                        label: const Text('Search'),
                      ),
                    ],
                  );
                },
              ),
            ],
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 24),
              MediaRow(
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
            ],
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

class _TmdbCredit extends StatelessWidget {
  const _TmdbCredit();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
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
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.pageGutter,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Browse by genre',
            style:
                theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            enabled
                ? 'Five lanes from the TMDB catalogue.'
                : 'Genre browsing needs a TMDB token.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
        ],
      ),
    );
  }
}
