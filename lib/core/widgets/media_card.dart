import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/design_tokens.dart';
import '../../core/widgets/media_meta.dart';
import '../../models/media_item.dart';

class MediaCard extends StatelessWidget {
  const MediaCard({required this.item, super.key});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final poster = item.posterPath;
    final theme = Theme.of(context);
    return SizedBox(
      width: DesignTokens.cardWidth,
      child: InkWell(
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusCard),
        onTap: () => context.push('/details/${item.ref.routeKey}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: DesignTokens.cardAspect,
              child: Container(
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
                        imageUrl:
                            '${AppConfig.tmdbImageBaseUrl}/w342$poster',
                        width: double.infinity,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => const ColoredBox(
                          color: DesignTokens.surface2,
                        ),
                        errorWidget: (_, _, _) =>
                            _PosterFallback(title: item.title),
                      ),
              ),
            ),
            const SizedBox(height: DesignTokens.space2),
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
              typeLabel:
                  item.type == MediaType.movie ? 'Movie' : 'Series',
            ),
          ],
        ),
      ),
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
