import 'package:flutter/material.dart';

import '../design_tokens.dart';

class AppError extends StatelessWidget {
  const AppError({
    required this.title,
    this.detail,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.secondary,
    super.key,
  });

  final String title;
  final String? detail;
  final VoidCallback? onRetry;
  final String retryLabel;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondaryWidget = secondary;
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
                  border: Border.all(color: DesignTokens.lineStrong),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.error_outline,
                  color: DesignTokens.danger,
                  size: 28,
                ),
              ),
              const SizedBox(height: DesignTokens.space4),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (detail != null) ...[
                const SizedBox(height: DesignTokens.space2),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: DesignTokens.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: DesignTokens.space4),
              Wrap(
                spacing: DesignTokens.space2,
                runSpacing: DesignTokens.space2,
                alignment: WrapAlignment.center,
                children: [
                  // ignore: use_null_aware_elements
                  if (secondaryWidget != null) secondaryWidget,
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(retryLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
