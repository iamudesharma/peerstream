import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design_tokens.dart';
import '../format.dart';
import '../image_url.dart';
import '../../models/media_item.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({required this.item, super.key});
  final MediaItem item;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final poster = resolveImageUrl(item.posterPath, tmdbSize: 'w342');
    final active = _hovered || _focused;
    final year = formatYear(item.releaseDate);
    final metadata = [
      if (year.isNotEmpty) year,
      item.type == MediaType.movie ? 'Movie' : 'Series',
    ].join(' · ');
    final fallback = ColoredBox(
      color: DesignTokens.surface2,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.movie_outlined,
                size: 36,
                color: DesignTokens.textTertiary,
              ),
              const SizedBox(height: 12),
              Text(
                item.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: DesignTokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
    final artwork = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(
          color: active ? DesignTokens.accent : DesignTokens.line,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster == null)
            fallback
          else
            CachedNetworkImage(
              imageUrl: poster,
              fit: BoxFit.cover,
              memCacheWidth: 342,
              maxWidthDiskCache: 342,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (_, _) =>
                  const ColoredBox(color: DesignTokens.surface2),
              errorWidget: (_, _, _) => fallback,
            ),
          if (item.rating > 0)
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xCC0F0F11),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      size: 13,
                      color: DesignTokens.warn,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      formatRating(item.rating),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: active ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: const ColoredBox(
                color: Color(0x55000000),
                child: Center(
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: DesignTokens.accent,
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      label: 'Explore ${item.title}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
          onTap: () => context.push('/details/${item.ref.routeKey}'),
          child: SizedBox(
            width: DesignTokens.cardWidth,
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (constraints.hasBoundedHeight)
                    Flexible(
                      child: AspectRatio(
                        aspectRatio: DesignTokens.cardAspect,
                        child: artwork,
                      ),
                    )
                  else
                    AspectRatio(
                      aspectRatio: DesignTokens.cardAspect,
                      child: artwork,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DesignTokens.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
