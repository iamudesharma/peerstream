import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../format.dart';

enum BadgeTone { neutral, accent, warn, danger }

class Badge extends StatelessWidget {
  const Badge({required this.label, this.tone = BadgeTone.neutral, this.icon, super.key});

  final String label;
  final BadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (background, border, foreground) = switch (tone) {
      BadgeTone.neutral => (
          DesignTokens.surface2,
          DesignTokens.lineStrong,
          DesignTokens.textSecondary
        ),
      BadgeTone.accent => (
          DesignTokens.accentDim,
          DesignTokens.accent.withValues(alpha: 0.5),
          DesignTokens.accent
        ),
      BadgeTone.warn => (
          DesignTokens.warn.withValues(alpha: 0.14),
          DesignTokens.warn.withValues(alpha: 0.4),
          DesignTokens.warn
        ),
      BadgeTone.danger => (
          DesignTokens.danger.withValues(alpha: 0.14),
          DesignTokens.danger.withValues(alpha: 0.4),
          DesignTokens.danger
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({
    required this.color,
    required this.semanticLabel,
    this.size = 8,
    super.key,
  });

  final Color color;
  final String semanticLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

Badge? qualityBadge(String sourceName) {
  final quality = formatQuality(sourceName);
  if (quality == null) return null;
  return Badge(label: quality, icon: Icons.high_quality_outlined);
}
