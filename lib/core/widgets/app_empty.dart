import 'package:flutter/material.dart';

import '../design_tokens.dart';

class AppEmpty extends StatelessWidget {
  const AppEmpty({
    required this.icon,
    required this.title,
    this.hint,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(DesignTokens.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: DesignTokens.surface2,
                  border: Border.all(color: DesignTokens.line),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: DesignTokens.textSecondary,
                  size: 28,
                ),
              ),
              const SizedBox(height: DesignTokens.space4),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (hint != null) ...[
                const SizedBox(height: DesignTokens.space2),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: DesignTokens.textSecondary,
                  ),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: DesignTokens.space4),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
