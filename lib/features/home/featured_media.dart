import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/gap_widgets.dart';
import 'package:peerstream/core/icons.dart';
import 'package:peerstream/core/navigation.dart';

import '../../core/design_tokens.dart';
import '../../core/image_url.dart';
import '../../core/widgets/media_meta.dart';
import '../../models/media_item.dart';

/// Uses the same catalogue item and details route as the discovery shelves.
class FeaturedMedia extends StatelessWidget {
  const FeaturedMedia({required this.item, super.key});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final image = resolveImageUrl(item.backdropPath, tmdbSize: 'w1280');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DesignTokens.pageGutter,
        8,
        DesignTokens.pageGutter,
        8,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: DesignTokens.surface2,
                    child: image == null
                        ? const SizedBox.shrink()
                        : Image.network(
                            image,
                            fit: BoxFit.cover,
                            alignment: Alignment.centerRight,
                            cacheWidth: 1280,
                            errorWidget: const SizedBox.shrink(),
                          ),
                  ),
                ),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xF219191D),
                          Color(0xC019191D),
                          Color(0x3819191D),
                        ],
                        stops: [0, 0.5, 1],
                      ),
                    ),
                    child: SizedBox.expand(),
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: narrow ? 340 : 410),
                  child: Padding(
                    padding: EdgeInsets.all(narrow ? 24 : 40),
                    child: SizedBox(
                      width: narrow
                          ? double.infinity
                          : constraints.maxWidth * 0.6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'IN THE SPOTLIGHT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2.5,
                              color: DesignTokens.accent,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            item.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: narrow ? 30 : 44,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.3,
                              height: 1.08,
                            ),
                          ),
                          const SizedBox(height: 16),
                          MediaMeta(
                            year: item.releaseDate,
                            rating: item.rating,
                            typeLabel: item.type == MediaType.movie
                                ? 'Movie'
                                : 'Series',
                          ),
                          if (item.overview.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              item.overview,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: DesignTokens.textSecondary,
                                height: 1.6,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          filledIconButton(
                            onPressed: () =>
                                context.push('/details/${item.ref.routeKey}'),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Explore title'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
