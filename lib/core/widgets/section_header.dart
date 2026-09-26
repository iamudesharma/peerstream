import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.pageGutter),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
          if (count != null) ...[
            const SizedBox(width: DesignTokens.space2),
            Text(
              '$count',
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textTertiary,
              ),
            ),
          ],

          if (onSeeAll != null)
            textIconButton(
              onPressed: onSeeAll,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: Text(seeAllLabel),
            ),
        ],
      ),
    );
  }
}
