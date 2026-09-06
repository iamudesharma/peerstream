import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../format.dart';

class MediaMeta extends StatelessWidget {
  const MediaMeta({
    this.year,
    this.rating = 0,
    this.runtimeMinutes,
    this.typeLabel,
    super.key,
  });

  final String? year;
  final double rating;
  final int? runtimeMinutes;
  final String? typeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final yearText = formatYear(year);
    final ratingText = formatRating(rating);
    final runtimeText = formatRuntime(runtimeMinutes);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: DesignTokens.textSecondary,
    );
    return Wrap(
      spacing: DesignTokens.space3,
      runSpacing: DesignTokens.space1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (yearText.isNotEmpty) Text(yearText, style: style),
        if (ratingText.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.star,
                size: 14,
                color: DesignTokens.warn,
                semanticLabel: 'Rating',
              ),
              const SizedBox(width: 4),
              Text(ratingText, style: style),
            ],
          ),
        if (runtimeText.isNotEmpty) Text(runtimeText, style: style),
        if (typeLabel != null) Text(typeLabel!, style: style),
      ],
    );
  }
}
