import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/section_header.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_item.dart';
import 'media_card.dart';

class MediaRow extends StatelessWidget {
  const MediaRow({
    required this.title,
    required this.items,
    this.onSeeAll,
    this.seeAllLabel = 'See all',
    this.demoBadge = false,
    super.key,
  });

  final String title;
  final AsyncValue<List<MediaItem>> items;
  final VoidCallback? onSeeAll;
  final String seeAllLabel;
  final bool demoBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (demoBadge)
          Padding(
            padding: const EdgeInsets.only(
              left: DesignTokens.pageGutter,
              right: DesignTokens.pageGutter,
              bottom: DesignTokens.space2,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: DesignTokens.accentDim,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: DesignTokens.accent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Text(
                    'Always available',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: DesignTokens.accent,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          items.when(
            data: (media) => SectionHeader(
              title: title,
              count: media.isEmpty ? null : media.length,
              onSeeAll: onSeeAll,
              seeAllLabel: seeAllLabel,
            ),
            loading: () => SectionHeader(title: title),
            error: (_, _) => SectionHeader(title: title),
          ),
        const SizedBox(height: DesignTokens.space3),
        SizedBox(
          height: 252,
          child: items.when(
            loading: () => const MediaRowSkeleton(),
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.pageGutter,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AppError(
                    title: 'Could not load $title',
                    detail: friendlyError(error),
                    retryLabel: 'Retry',
                  ),
                ),
              ),
            ),
            data: (media) => media.isEmpty
                ? const AppEmpty(
                    icon: Icons.movie_outlined,
                    title: 'Nothing here yet',
                    hint: 'Check back later for new titles.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DesignTokens.pageGutter,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: media.length,
                    separatorBuilder: (_, _) => const SizedBox(
                      width: DesignTokens.space3,
                    ),
                    itemBuilder: (_, index) =>
                        MediaCard(item: media[index]),
                  ),
          ),
        ),
      ],
    );
  }
}
