import 'package:peerstream/core/navigation.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../design_tokens.dart';
import '../format.dart';
import '../image_url.dart';
import '../../models/media_item.dart';

class MediaCard extends StatelessWidget {
  const MediaCard({required this.item, super.key});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final poster = resolveImageUrl(item.posterPath, tmdbSize: 'w342');
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
    final artwork = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.line, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (poster == null)
              fallback
            else
              Image.network(
                poster,
                fit: BoxFit.cover,
                cacheWidth: 342,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: const ColoredBox(color: DesignTokens.surface2),
                errorWidget: fallback,
              ),
            if (item.rating > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0F0F11),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.star,
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
          ],
        ),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
      onTap: () => context.push('/details/${item.ref.routeKey}'),
      child: SizedBox(
        width: DesignTokens.cardWidth,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (constraints.maxHeight.isFinite)
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
    );
  }
}
