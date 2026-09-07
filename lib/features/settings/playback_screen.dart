import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/playback/playback_cache_models.dart';
import '../../services/settings/settings_store.dart';

class PlaybackScreen extends ConsumerWidget {
  const PlaybackScreen({super.key});

  static const _cacheLimits = <int>[
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

  Future<void> _setCacheLimit(
    BuildContext context,
    WidgetRef ref,
    int bytes,
  ) async {
    final cache = ref.read(playbackCacheProvider);
    final current = await cache.preferences();
    await cache.savePreferences(current.copyWith(maxCacheBytes: bytes));
    _refresh(ref);
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
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
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Playback & Storage')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Playback & Storage',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure cache, saved video, and language preferences.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
          ),
          const SizedBox(height: 16),
          SettingsSection(
            title: 'Storage',
            subtitle: 'Manage cached video files',
            children: [
              summary.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: AppEmpty(
                    icon: Icons.storage_outlined,
                    title: 'Could not read saved video',
                    hint: 'Try reopening this screen.',
                  ),
                ),
                data: (value) => _CacheSummary(
                  summary: value,
                  onLimit: (limit) => _setCacheLimit(context, ref, limit),
                  onClear: () => _clearCache(context, ref),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Language preferences',
            subtitle: 'Preferred audio and subtitle languages',
            children: [
              settings.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const SizedBox.shrink(),
                data: (s) => Column(
                  children: [
                    SettingsSelect<String>(
                      title: 'Preferred audio language',
                      icon: Icons.audiotrack_outlined,
                      value: s.preferredAudioLanguage ?? 'Default',
                      options: [
                        for (final lang in AppSettings.audioLanguages)
                          SelectOption(value: lang, label: lang),
                      ],
                      onChanged: (value) {
                        final notifier =
                            ref.read(appSettingsProvider.notifier);
                        notifier.setAudioLanguage(
                          value == 'Default' ? null : value,
                        );
                      },
                    ),
                    const Divider(height: 1),
                    SettingsSelect<String>(
                      title: 'Preferred subtitle language',
                      icon: Icons.subtitles_outlined,
                      value: s.preferredSubtitleLanguage ?? 'None',
                      options: [
                        for (final lang in AppSettings.subtitleLanguages)
                          SelectOption(value: lang, label: lang),
                      ],
                      onChanged: (value) {
                        final notifier =
                            ref.read(appSettingsProvider.notifier);
                        notifier.setSubtitleLanguage(
                          value == 'None' ? null : value,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Playback engine',
            subtitle: 'Experimental backend selection',
            children: [
              settings.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const SizedBox.shrink(),
                data: (s) => Column(
                  children: [
                    SettingsToggle(
                      title: 'Use MediaForge Player (Experimental)',
                      subtitle:
                          'Use the experimental MediaForge playback engine instead of the default player. Applies to the next video you open.',
                      icon: Icons.science_outlined,
                      value: s.useMediaForgePlayer,
                      onChanged: (value) {
                        ref
                            .read(appSettingsProvider.notifier)
                            .setUseMediaForgePlayer(value);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Saved video',
            subtitle: 'Video files cached on this device',
            children: [
              entries.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const SizedBox.shrink(),
                data: (items) => items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: AppEmpty(
                          icon: Icons.video_library_outlined,
                          title: 'No saved video yet',
                          hint:
                              'Play a torrent and its downloaded parts will be kept here.',
                        ),
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
        ],
      ),
    );
  }
}

class _CacheSummary extends StatelessWidget {
  const _CacheSummary({
    required this.summary,
    required this.onLimit,
    required this.onClear,
  });
  final PlaybackCacheSummary summary;
  final ValueChanged<int> onLimit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
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
          itemBuilder: (context) => PlaybackScreen._cacheLimits
              .map(
                (limit) => PopupMenuItem(
                  value: limit,
                  child: Text(
                    '${formatBytes(limit)} limit${limit == summary.maxBytes ? ' · Current' : ''}',
                  ),
                ),
              )
              .toList(),
          child: const ListTile(
            leading: Icon(Icons.tune),
            title: Text('Cache limit'),
            trailing: Icon(Icons.arrow_drop_down),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('Clear saved video'),
          onTap: onClear,
        ),
      ],
    );
  }
}
