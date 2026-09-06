import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../models/torrent_models.dart';

class TorrentStatistics extends StatelessWidget {
  const TorrentStatistics({required this.stats, super.key});
  final TorrentStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (stats.totalBytes <= 0 && stats.downloadedBytes <= 0) {
      return const SizedBox.shrink();
    }
    final progress = stats.progress.isNaN
        ? 0.0
        : stats.progress.clamp(0.0, 1.0);
    return Container(
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius:
            BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.line),
      ),
      padding: const EdgeInsets.all(DesignTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.monitor_heart_outlined,
                size: 18,
                color: DesignTokens.textSecondary,
              ),
              const SizedBox(width: DesignTokens.space2),
              Text(
                'Transfer',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                formatPhase(stats.phase),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignTokens.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: DesignTokens.space3),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: DesignTokens.space2),
          Text(
            '${(progress * 100).toStringAsFixed(1)}% · ${formatBytes(stats.downloadedBytes)} of ${formatBytes(stats.totalBytes)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: DesignTokens.space3),
          Wrap(
            spacing: DesignTokens.space4,
            runSpacing: DesignTokens.space3,
            children: [
              _Stat(
                label: 'Download',
                value: formatSpeed(stats.downloadRate),
              ),
              _Stat(label: 'Upload', value: formatSpeed(stats.uploadRate)),
              _Stat(label: 'Peers', value: stats.peers?.toString() ?? '—'),
              _Stat(label: 'Seeds', value: stats.seeds?.toString() ?? '—'),
              _Stat(
                label: 'Buffer',
                value:
                    '${(stats.bufferProgress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: DesignTokens.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
