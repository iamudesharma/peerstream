import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/image_url.dart';
import '../../core/widgets/media_meta.dart';
import '../../models/media_item.dart';

class MediaCard extends StatelessWidget {
  const MediaCard({required this.item, super.key});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final poster = resolveImageUrl(item.posterPath, tmdbSize: 'w342');
    final theme = Theme.of(context);

    Widget buildPoster() {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            DesignTokens.radiusCard,
          ),
          border: Border.all(color: DesignTokens.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: poster == null
            ? _PosterFallback(title: item.title)
            : CachedNetworkImage(
                imageUrl: poster,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                // Downscale in memory + on disk to poster width to cut
                // memory and decode cost on low-end devices.
                memCacheWidth: 342,
                maxWidthDiskCache: 342,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (_, _) => const ColoredBox(
                  color: DesignTokens.surface2,
                ),
                errorWidget: (_, _, _) => _PosterFallback(title: item.title),
              ),
      );
    }

    Widget buildInfo() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          MediaMeta(
            year: item.releaseDate,
            rating: item.rating,
            typeLabel: item.type == MediaType.movie ? 'Movie' : 'Series',
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedWidth = constraints.maxWidth.isFinite;
        final hasBoundedHeight = constraints.maxHeight.isFinite;
        final isGridCell = hasBoundedWidth && hasBoundedHeight;

        // Grid / SliverGrid gives a tight w + h (e.g. 165.5 x 278/300).
        // Use a flexible layout that always fits the cell height and preserves
        // 2/3 aspect when possible, shrinking only under textScale.
        if (isGridCell) {
          return SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: InkWell(
              borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
              onTap: () => context.push('/details/${item.ref.routeKey}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: DesignTokens.cardAspect,
                      child: buildPoster(),
                    ),
                  ),
                  const SizedBox(height: DesignTokens.space2),
                  buildInfo(),
                ],
              ),
            ),
          );
        }

        // Horizontal ListView (MediaRow) or unconstrained: keep fixed
        // cardWidth with intrinsic height. Parent SizedBox(height: 252) is
        // tall enough for 132 * 1.5 = 198 poster + info.
        return SizedBox(
          width: DesignTokens.cardWidth,
          child: InkWell(
            borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
            onTap: () => context.push('/details/${item.ref.routeKey}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: DesignTokens.cardAspect,
                  child: buildPoster(),
                ),
                const SizedBox(height: DesignTokens.space2),
                buildInfo(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: DesignTokens.surface2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(DesignTokens.space3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.movie_filter_outlined,
            size: 32,
            color: DesignTokens.textTertiary,
          ),
          const SizedBox(height: DesignTokens.space2),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
