import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/badges.dart';
import '../../core/widgets/section_header.dart';
import '../../models/media_item.dart';
import '../../models/watch_progress.dart';
import '../../providers/app_providers.dart';

class ContinueWatchingRow extends ConsumerWidget {
  const ContinueWatchingRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(watchHistoryProvider);
    return history.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (entries) {
        if (entries.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SectionHeader(
              title: 'Continue Watching',
              count: entries.length,
              seeAllLabel: 'Clear',
              onSeeAll: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Clear history?'),
                    content: const Text(
                      'This removes every Continue Watching entry from this device.',
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
                  await ref.read(watchHistoryProvider.notifier).clear();
                }
              },
            ),
            const SizedBox(height: DesignTokens.space3),
            SizedBox(
              height: 236,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.pageGutter,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: entries.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: DesignTokens.space3),
                itemBuilder: (_, index) => _ContinueCard(entry: entries[index]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.entry});
  final WatchEntry entry;

  String _playerRoute() {
    return Uri(
      path: '/player/${entry.media.routeKey}',
      queryParameters: {
        'source': entry.sourceId,
        if (entry.season != null) 'season': '${entry.season}',
        if (entry.episode != null) 'episode': '${entry.episode}',
        'resume': '${entry.positionMs}',
      },
    ).toString();
  }

  String _sourcesRoute() {
    return Uri(
      path: '/sources/${entry.media.routeKey}',
      queryParameters: {
        if (entry.season != null) 'season': '${entry.season}',
        if (entry.episode != null) 'episode': '${entry.episode}',
      },
    ).toString();
  }

  Future<void> _resume(BuildContext context, WidgetRef ref) async {
    final cached = await ref.read(playbackCacheProvider).lookupWatch(entry);
    if (cached != null) {
      if (!context.mounted) return;
      context.push(_playerRoute());
      return;
    }
    try {
      final results = await ref.read(
        sourceResultsProvider((
          media: entry.media,
          season: entry.season,
          episode: entry.episode,
        )).future,
      );
      final available = results
          .expand((result) => result.sources)
          .any((source) => source.id == entry.sourceId);
      if (!context.mounted) return;
      if (available) {
        context.push(_playerRoute());
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('That source expired — pick a fresh one.'),
            ),
          );
        context.push(_sourcesRoute());
      }
    } catch (_) {
      if (!context.mounted) return;
      context.push(_playerRoute());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final episodeLabel =
        entry.media.type == MediaType.tv &&
            entry.season != null &&
            entry.episode != null
        ? 'S${entry.season} E${entry.episode}'
        : null;
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
            onTap: () => _resume(context, ref),
            child: Container(
              decoration: BoxDecoration(
                color: DesignTokens.surface,
                borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
                border: Border.all(color: DesignTokens.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Backdrop(entry: entry),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black54],
                        ),
                      ),
                    ),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          size: 28,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.remainingLabel(),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (episodeLabel != null)
                            Badge(label: episodeLabel, tone: BadgeTone.neutral),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: entry.progress.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        color: DesignTokens.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: DesignTokens.space2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.providerName.isEmpty
                          ? 'Resume from ${formatWatchTimestamp(entry.position)}'
                          : '${entry.providerName} · ${formatWatchTimestamp(entry.position)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: DesignTokens.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () =>
                    ref.read(watchHistoryProvider.notifier).remove(entry.key),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Tooltip(
                    message: 'Remove',
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: DesignTokens.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.entry});
  final WatchEntry entry;

  @override
  Widget build(BuildContext context) {
    final backdrop = entry.backdropPath;
    if (backdrop != null) {
      return CachedNetworkImage(
        imageUrl: '${AppConfig.tmdbImageBaseUrl}/w780$backdrop',
        fit: BoxFit.cover,
        placeholder: (_, _) => const ColoredBox(color: DesignTokens.surface2),
        errorWidget: (_, _, _) => _BackdropFallback(entry: entry),
      );
    }
    final poster = entry.posterPath;
    if (poster != null) {
      return CachedNetworkImage(
        imageUrl: '${AppConfig.tmdbImageBaseUrl}/w342$poster',
        fit: BoxFit.cover,
        placeholder: (_, _) => const ColoredBox(color: DesignTokens.surface2),
        errorWidget: (_, _, _) => _BackdropFallback(entry: entry),
      );
    }
    return _BackdropFallback(entry: entry);
  }
}

class _BackdropFallback extends StatelessWidget {
  const _BackdropFallback({required this.entry});
  final WatchEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DesignTokens.surface2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(DesignTokens.space3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.movie_outlined,
            size: 28,
            color: DesignTokens.textTertiary,
          ),
          const SizedBox(width: DesignTokens.space2),
          Flexible(
            child: Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: DesignTokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class ContinueWatchingEmpty extends StatelessWidget {
  const ContinueWatchingEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppEmpty(
      icon: Icons.history_outlined,
      title: 'Nothing to resume yet',
      hint: 'Play any video and it will show up here.',
    );
  }
}
