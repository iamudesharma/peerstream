import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/media_meta.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/saved_item.dart';
import '../../providers/app_providers.dart';
import '../episodes/episode_selection.dart';

class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({required this.mediaRef, super.key});
  final MediaRef mediaRef;

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  @override
  Widget build(BuildContext context) {
    final details = ref.watch(detailsProvider(widget.mediaRef));
    final myList = ref.watch(myListProvider);
    final isSaved = myList.value?.any(
          (item) => item.media == widget.mediaRef,
        ) ??
        false;
    final loadedItem = details.value?.item;
    return Scaffold(
      appBar: AppBar(
        title: details.when(
          data: (value) => Text(
            value.item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          loading: () => const Text('Details'),
          error: (_, _) => const Text('Details'),
        ),
        actions: [
          IconButton(
            tooltip: isSaved ? 'Remove from watchlist' : 'Save to watchlist',
            icon: Icon(
              isSaved ? Icons.bookmark : Icons.bookmark_border,
              color: isSaved ? DesignTokens.accent : null,
            ),
            onPressed: loadedItem == null
                ? null
                : () async {
                    final wasSaved = ref
                        .read(myListProvider.notifier)
                        .isSaved(widget.mediaRef);
                    await ref
                        .read(myListProvider.notifier)
                        .toggle(SavedItem.fromMediaItem(loadedItem));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            wasSaved
                                ? 'Removed from watchlist'
                                : 'Saved to watchlist',
                          ),
                          action: SnackBarAction(
                            label: 'Undo',
                            onPressed: () {
                              ref
                                  .read(myListProvider.notifier)
                                  .toggle(SavedItem.fromMediaItem(loadedItem));
                            },
                          ),
                        ),
                      );
                  },
          ),
        ],
      ),
      body: details.when(
        loading: () => ListView(
          children: const [
            BackdropSkeleton(),
            SizedBox(height: DesignTokens.space4),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: DesignTokens.pageGutter,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 260, height: 26),
                  SizedBox(height: DesignTokens.space2),
                  SkeletonBox(width: 180, height: 12),
                  SizedBox(height: DesignTokens.space3),
                  SkeletonBox(width: double.infinity, height: 12),
                  SizedBox(height: DesignTokens.space2),
                  SkeletonBox(width: double.infinity, height: 12),
                ],
              ),
            ),
          ],
        ),
        error: (error, _) => AppError(
          title: 'Could not load details',
          detail: friendlyError(error),
          onRetry: () => ref.invalidate(detailsProvider(widget.mediaRef)),
          retryLabel: 'Retry',
          secondary: OutlinedButton.icon(
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Go back'),
          ),
        ),
        data: (value) => _DetailsBody(details: value),
      ),
    );
  }
}

class _DetailsBody extends StatefulWidget {
  const _DetailsBody({required this.details});
  final MediaDetails details;

  @override
  State<_DetailsBody> createState() => _DetailsBodyState();
}

class _DetailsBodyState extends State<_DetailsBody> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.details.item;
    final backdrop = item.backdropPath;
    return ListView(
      children: [
        AspectRatio(
          aspectRatio: 16 / 7,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backdrop != null)
                CachedNetworkImage(
                  imageUrl:
                      '${AppConfig.tmdbImageBaseUrl}/w1280$backdrop',
                  fit: BoxFit.cover,
                  placeholder: (_, _) => const ColoredBox(
                    color: DesignTokens.surface2,
                  ),
                  errorWidget: (_, _, _) => const _BackdropFallback(),
                )
              else
                const _BackdropFallback(),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      DesignTokens.background,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            DesignTokens.pageGutter,
            0,
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
                  Badge(
                    label:
                        item.type == MediaType.movie ? 'Movie' : 'Series',
                    tone: BadgeTone.accent,
                    icon: item.type == MediaType.movie
                        ? Icons.movie_outlined
                        : Icons.tv_outlined,
                  ),
                  const SizedBox(height: DesignTokens.space2),
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.08,
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space2),
                  MediaMeta(
                    year: item.releaseDate,
                    rating: item.rating,
                    runtimeMinutes: widget.details.runtimeMinutes,
                  ),
                  if (widget.details.genres.isNotEmpty) ...[
                    const SizedBox(height: DesignTokens.space3),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.details.genres
                          .map((genre) => Chip(label: Text(genre)))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: DesignTokens.space4),
                  if (item.overview.isEmpty)
                    Text(
                      'No overview is available for this title yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: DesignTokens.textTertiary,
                      ),
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.overview,
                          maxLines: _expanded ? null : 4,
                          overflow: _expanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: DesignTokens.textSecondary,
                            height: 1.6,
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          child: Text(
                            _expanded ? 'Show less' : 'Show more',
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: DesignTokens.space2),
                  if (item.type == MediaType.movie)
                    _MovieActions(item: item)
                  else
                    EpisodeSelection(
                      seriesId: item.id,
                      seasons: widget.details.seasons,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BackdropFallback extends StatelessWidget {
  const _BackdropFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: DesignTokens.surface2,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 40,
          color: DesignTokens.textTertiary,
        ),
      ),
    );
  }
}

class _MovieActions extends ConsumerWidget {
  const _MovieActions({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sources = ref.watch(
      sourceListProvider(item.ref),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: () =>
                  context.push('/sources/${item.ref.routeKey}'),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Find sources'),
            ),
            const SizedBox(width: 12),
            sources.when(
              data: (list) => Text(
                list.isEmpty
                    ? 'No sources cached'
                    : '${list.length} source${list.length == 1 ? '' : 's'} found',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textTertiary,
                ),
              ),
              loading: () => Text(
                'Checking sources',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textTertiary,
                ),
              ),
              error: (_, _) => Text(
                'Source check unavailable',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
