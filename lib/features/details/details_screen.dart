import 'package:peerstream/core/gap_widgets.dart';
import 'package:peerstream/providers/app_store.dart';
import 'package:peerstream/core/navigation.dart';
import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:dartnative/dartnative.dart' hide Badge;
import 'package:peerstream/core/icons.dart';

import '../../core/image_url.dart';
import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/media_meta.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_details.dart';
import '../../models/media_item.dart';
import '../../models/saved_item.dart';
import '../episodes/episode_selection.dart';

class DetailsScreen extends StatefulWidget {
  const DetailsScreen({required this.mediaRef, super.key});
  final MediaRef mediaRef;

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  @override
  void initState() {
    super.initState();
    // Warm the torrent session while the user reads details/picks an
    // episode, so Sources -> Play pays no cold-start cost.
    Future.microtask(() {
      if (!mounted) return;
      // ignore: discarded_futures
      AppStore.instance.streaming.warmUp();
    });
  }

  @override
  Widget build(BuildContext context) {
    final details = (AppStore.instance.detailsFor(widget.mediaRef)..watch(context));
    final myList = (AppStore.instance.myList..watch(context));
    final isSaved = myList.value?.any(
          (item) => item.media == widget.mediaRef,
        ) ??
        false;
    final loadedItem = details.value?.item;
    return Scaffold(
      // The screen colour belongs on the Scaffold: with no backgroundColor the
      // route reports the white default and dark screens flash white.
      backgroundColor: DesignTokens.background,
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
            icon: Icon(
              isSaved ? Icons.bookmark : Icons.bookmark_border,
              color: isSaved ? DesignTokens.accent : null,
            ),
            onPressed: loadedItem == null
                ? null
                : () async {
                    final wasSaved = AppStore.instance.myList.isSaved(
                      widget.mediaRef,
                    );
                    await AppStore.instance.myList.toggle(
                      SavedItem.fromMediaItem(loadedItem),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
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
                              AppStore.instance.myList.toggle(
                                SavedItem.fromMediaItem(loadedItem),
                              );
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
          onRetry: () =>
              AppStore.instance.detailsFor(widget.mediaRef).reload(),
          retryLabel: 'Retry',
          secondary: outlinedIconButton(
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
    final backdrop = resolveImageUrl(item.backdropPath, tmdbSize: 'w1280');
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return ListView(
      children: [
        SizedBox(
          height: wide ? 480 : 350,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (backdrop != null)
                Image.network(
                  backdrop,
                  fit: BoxFit.cover,
                  // The hero is a full-bleed 350dp band; decoding the 1280px
                  // source on both axes is what pushed this screen into the
                  // image-cache thrash.
                  cacheWidth: wide ? 1280 : 780,
                  cacheHeight: wide ? 720 : 420,
                  fadeInDuration: const Duration(milliseconds: 150),
                  placeholder: const ColoredBox(color: DesignTokens.surface2),
                  errorWidget: const _BackdropFallback(),
                )
              else
                const _BackdropFallback(),
              const DecoratedBox(
                child: SizedBox.expand(),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black54,
                      DesignTokens.background,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // No Center/ConstrainedBox in here: an unconstrained
                // centering wrapper collapses on this runtime and dragged the
                // whole overlay onto the bottom edge.
                child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DesignTokens.pageGutter,
                        0,
                        DesignTokens.pageGutter,
                        DesignTokens.space4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Badge(
                            label: item.type == MediaType.movie
                                ? 'Movie'
                                : 'Series',
                            tone: BadgeTone.accent,
                            icon: item.type == MediaType.movie
                                ? Icons.movie_outlined
                                : Icons.tv_outlined,
                          ),
                          const SizedBox(height: DesignTokens.space2),
                          Text(
                            item.title,
                            maxLines: 2,
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
            DesignTokens.space4,
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
                  if (item.type == MediaType.movie)
                    _MovieActions(item: item)
                  else
                    EpisodeSelection(
                      seriesId: item.id,
                      seasons: widget.details.seasons,
                    ),
                  if (widget.details.genres.isNotEmpty) ...[
                    const SizedBox(height: DesignTokens.space4),
                    Wrap(
                      spacing: DesignTokens.space2,
                      runSpacing: DesignTokens.space2,
                      children: widget.details.genres
                          .map((genre) => Chip(label: Text(genre)))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: DesignTokens.space6),
                  Text('The story', style: theme.textTheme.titleLarge),
                  const SizedBox(height: DesignTokens.space3),
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
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(_expanded ? 'Show less' : 'Show more'),
                        ),
                      ],
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

class _MovieActions extends StatelessWidget {
  const _MovieActions({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = AppStore.instance.discovery((
      media: item.ref,
      season: null,
      episode: null,
    ))..watch(context);
    final count = sources.value?.allSources.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: filledIconButton(
            onPressed: () =>
                context.push('/sources/${item.ref.routeKey}'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Find sources'),
          ),
        ),
        const SizedBox(height: DesignTokens.space2),
        Text(
          sources.hasError
              ? 'Source check unavailable'
              : count == null
              ? 'Checking sources'
              : count == 0
              ? 'No sources cached'
              : '$count source${count == 1 ? '' : 's'} found',
          style: theme.textTheme.bodySmall?.copyWith(
            color: DesignTokens.textTertiary,
          ),
        ),
      ],
    );
  }
}
