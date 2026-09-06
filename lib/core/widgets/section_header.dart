import 'package:flutter/material.dart';

import '../design_tokens.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.count,
    this.onSeeAll,
    this.seeAllLabel = 'See all',
    super.key,
  });

  final String title;
  final int? count;
  final VoidCallback? onSeeAll;
  final String seeAllLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.pageGutter,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (count != null) ...[
            const SizedBox(width: DesignTokens.space2),
            Text(
              '$count',
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          if (onSeeAll != null)
            TextButton.icon(
              onPressed: onSeeAll,
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: Text(seeAllLabel),
            ),
        ],
      ),
    );
  }
}
