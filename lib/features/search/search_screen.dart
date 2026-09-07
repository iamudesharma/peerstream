import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../core/widgets/media_card.dart';
import '../../core/widgets/skeletons.dart';
import '../../providers/app_providers.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final tmdb = AppConfig.hasTmdbToken;
    final enabled = tmdb || AppConfig.hasStreamingCatalogs;
    final results = (_query.isEmpty || !enabled)
        ? null
        : ref.watch(searchResultsProvider(_query));
    return AppScaffold(
      selectedIndex: 1,
      title: 'Search',
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                DesignTokens.pageGutter,
                24,
                DesignTokens.pageGutter,
                DesignTokens.space4,
              ),
              child: TextField(
                controller: _controller,
                onChanged: _onChanged,
                autofocus: enabled,
                enabled: enabled,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search movies and series',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.clear),
                          onPressed: _clear,
                        ),
                ),
              ),
            ),
          ),
          if (!enabled)
            SliverFillRemaining(
              child: AppEmpty(
                icon: Icons.key_outlined,
                title: 'Search needs a TMDB token',
                hint:
                    'Relaunch with --dart-define=TMDB_READ_TOKEN=your_token. The open movies on Home still play.',
                action: FilledButton.icon(
                  onPressed: () => context.go('/'),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Back to Home'),
                ),
              ),
            ),
          if (enabled && !tmdb)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  DesignTokens.pageGutter,
                  0,
                  DesignTokens.pageGutter,
                  DesignTokens.space2,
                ),
                child: Text(
                  'Keyless search via Cinemeta \u00b7 No API key',
                  style: TextStyle(
                    color: DesignTokens.textTertiary,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          if (enabled && results == null)
            SliverFillRemaining(
              child: AppEmpty(
                icon: Icons.search,
                title: 'Search the catalogue',
                hint: 'Type at least two characters. Results appear as you type.',
                action: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ActionChip(
                      label: const Text('Trending movies'),
                      onPressed: () => context.push(
                        '/category/movie/0?title=${Uri.encodeComponent('Trending movies')}',
                      ),
                    ),
                    ActionChip(
                      label: const Text('Trending series'),
                      onPressed: () => context.push(
                        '/category/tv/0?title=${Uri.encodeComponent('Trending series')}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (enabled && results != null)
            results.when(
              loading: () => const SliverSkeletonGrid(),
              error: (error, _) => SliverFillRemaining(
                child: AppError(
                  title: 'Search failed',
                  detail: friendlyError(error),
                  onRetry: () =>
                      ref.invalidate(searchResultsProvider(_query)),
                  retryLabel: 'Retry search',
                ),
              ),
              data: (items) => items.isEmpty
                  ? const SliverFillRemaining(
                      child: AppEmpty(
                        icon: Icons.search_off_outlined,
                        title: 'No results found',
                        hint:
                            'Check the spelling or try a different title.',
                      ),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.all(
                        DesignTokens.pageGutter,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: DesignTokens.gridMaxExtent,
                          mainAxisExtent: 300,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, index) =>
                            MediaCard(item: items[index]),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
