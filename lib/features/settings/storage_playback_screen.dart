import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_scaffold.dart';
import '../../providers/app_providers.dart';
import '../../services/playback/playback_cache_models.dart';

class StoragePlaybackScreen extends ConsumerWidget {
  const StoragePlaybackScreen({super.key});

  static const _limits = <int>[
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    3 * 1024 * 1024 * 1024,
    5 * 1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
  ];

  void _refresh(WidgetRef ref) {
    ref.invalidate(playbackCacheSummaryProvider);
    ref.invalidate(playbackCacheEntriesProvider);
  }

  Future<void> _setLimit(BuildContext context, WidgetRef ref, int bytes) async {
    final cache = ref.read(playbackCacheProvider);
    final current = await cache.preferences();
    await cache.savePreferences(current.copyWith(maxCacheBytes: bytes));
    _refresh(ref);
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear saved video?'),
        content: const Text(
          'This removes saved torrent video from this device. Continue Watching stays available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep video'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear saved video'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playbackCacheProvider).clear();
    _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(playbackCacheSummaryProvider);
    final entries = ref.watch(playbackCacheEntriesProvider);
    return AppScaffold(
      selectedIndex: 2,
      title: 'Storage & playback',
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Storage & playback',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'Played torrent video stays on this device for quicker replay. The oldest inactive video is removed when the limit is reached.',
          ),
          const SizedBox(height: 20),
          summary.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const AppEmpty(
              icon: Icons.storage_outlined,
              title: 'Could not read saved video',
              hint: 'Try reopening this screen.',
            ),
            data: (value) => _StorageSummary(
              summary: value,
              onLimit: (limit) => _setLimit(context, ref, limit),
              onClear: () => _clear(context, ref),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Saved video',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          entries.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => const SizedBox.shrink(),
            data: (items) => items.isEmpty
                ? const AppEmpty(
                    icon: Icons.video_library_outlined,
                    title: 'No saved video yet',
                    hint: 'Play a torrent and its downloaded parts will be kept here.',
                  )
                : Column(
                    children: [
                      for (final item in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            item.complete
                                ? Icons.offline_pin_outlined
                                : Icons.downloading_outlined,
                          ),
                          title: Text(
                            item.source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.complete
                                ? 'Ready offline · ${formatBytes(item.byteSize)}'
                                : 'Partly downloaded · ${formatBytes(item.byteSize)}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove saved video',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await ref
                                  .read(playbackCacheProvider)
                                  .remove(item.cacheKey);
                              _refresh(ref);
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _StorageSummary extends StatelessWidget {
  const _StorageSummary({
    required this.summary,
    required this.onLimit,
    required this.onClear,
  });
  final PlaybackCacheSummary summary;
  final ValueChanged<int> onLimit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text('${formatBytes(summary.byteSize)} used'),
          subtitle: Text(
            '${summary.entries} saved source${summary.entries == 1 ? '' : 's'}',
          ),
        ),
        const Divider(height: 1),
        PopupMenuButton<int>(
          onSelected: onLimit,
          itemBuilder: (context) => StoragePlaybackScreen._limits
              .map(
                (limit) => PopupMenuItem(
                  value: limit,
                  child: Text(
                    '${formatBytes(limit)} limit${limit == summary.maxBytes ? ' · Current' : ''}',
                  ),
                ),
              )
              .toList(),
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Cache limit'),
            trailing: Text(formatBytes(summary.maxBytes)),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('Clear saved video'),
          onTap: onClear,
        ),
      ],
    ),
  );
}
