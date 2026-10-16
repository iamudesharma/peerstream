import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_forge_player/media_forge_player.dart'
    show VideoEnhancementMode;

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/image_cache.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../core/widgets/storage_feedback.dart';
import '../../providers/app_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/playback/playback_cache_models.dart';
import '../../services/settings/settings_store.dart';
import '../../services/torrent/torrent_engine.dart';
import '../player/player_backend.dart';
import '../../services/storage/app_storage.dart';
import 'storage_directory_tile.dart';
import 'offline_downloads_section.dart';
import '../../services/local_service/service_backend.dart';

class PlaybackScreen extends ConsumerStatefulWidget {
  const PlaybackScreen({super.key});

  static const _cacheLimits = <int>[
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    3 * 1024 * 1024 * 1024,
    5 * 1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
  ];

  @override
  ConsumerState<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends ConsumerState<PlaybackScreen> {
  bool _clearing = false;

  void _refresh(WidgetRef ref) {
    ref.invalidate(playbackCacheSummaryProvider);
    ref.invalidate(playbackCacheEntriesProvider);
  }

  Future<void> _setCacheLimit(
    BuildContext context,
    WidgetRef ref,
    int bytes,
  ) async {
    final saved = await runStorageAction(context, () async {
      final cache = ref.read(playbackCacheProvider);
      final current = await cache.preferences();
      await cache.savePreferences(current.copyWith(maxCacheBytes: bytes));
    });
    if (saved && context.mounted) _refresh(ref);
  }

  Future<void> _clearCache() async {
    if (_clearing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all cached data?'),
        content: const Text(
          'This removes cached video, offline saves, artwork and subtitle copies. Watch history, saved titles, providers and settings stay available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep cache'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    final service = ref.read(streamingServiceProvider);
    final cache = ref.read(playbackCacheProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      // Release retained native handles before deleting files they can still
      // read/write. Keep the service usable for the next playback session.
      await service.clearCache(() async {
        await cache.clear();
        await clearArtworkCache();
        await appStorage.clearAuxiliaryCache();
      });
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      try {
        container.invalidate(playbackCacheSummaryProvider);
        container.invalidate(playbackCacheEntriesProvider);
      } on StateError {
        // The app may close while its already-authorized cleanup is running.
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Cached data cleared.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear cached data: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(playbackCacheSummaryProvider);
    final entries = ref.watch(playbackCacheEntriesProvider);
    final settings = ref.watch(appSettingsProvider);
    final enhancementCapabilities = ref.watch(
      mediaForgeVideoEnhancementCapabilitiesProvider,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Playback & Storage')),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.pageGutter),
        children: [
          Text(
            'Playback & Storage',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure cache, saved video, and language preferences.',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: DesignTokens.textSecondary),
          ),
          const SizedBox(height: 16),
          if (settings.hasError)
            StorageRetryTile(
              onRetry: () => ref.invalidate(appSettingsProvider),
            ),
          SettingsSection(
            title: 'Streaming engine',
            children: [
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(
                  serviceExperimentEnabled
                      ? 'Rust service · experimental'
                      : 'Built-in native engine',
                ),
                subtitle: const Text(
                  'The Rust service uses an isolated prototype cache. Background mode and launch at login remain unavailable until packaged-app acceptance passes.',
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Performance',
            children: [
              ListTile(
                title: const Text('Memory profile'),
                subtitle: const Text(
                  'Piece cache budget; total application memory also includes video and artwork.',
                ),
                trailing: DropdownButton<PlaybackResourceProfile>(
                  value:
                      settings.value?.resourceProfile ??
                      PlaybackResourceProfile.balanced,
                  items: const [
                    DropdownMenuItem(
                      value: PlaybackResourceProfile.balanced,
                      child: Text('Balanced'),
                    ),
                    DropdownMenuItem(
                      value: PlaybackResourceProfile.lowMemory,
                      child: Text('Low memory'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      runStorageAction(
                        context,
                        () => ref
                            .read(appSettingsProvider.notifier)
                            .setResourceProfile(value),
                      );
                    }
                  },
                ),
              ),
              SwitchListTile(
                title: const Text('Autoplay next episode'),
                subtitle: const Text(
                  'Show a cancelable countdown when an episode ends.',
                ),
                value: settings.value?.autoplay ?? false,
                onChanged: (value) => runStorageAction(
                  context,
                  () =>
                      ref.read(appSettingsProvider.notifier).setAutoplay(value),
                ),
              ),
            ],
          ),
          const OfflineDownloadsSection(),
          SettingsSection(
            title: 'Storage',
            subtitle: 'Choose where PeerStream saves data and manage its cache',
            children: [
              const StorageDirectoryTile(),
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
                  onClear: _clearCache,
                  clearing: _clearing,
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
                        final notifier = ref.read(appSettingsProvider.notifier);
                        runStorageAction(
                          context,
                          () => notifier.setAudioLanguage(
                            value == 'Default' ? null : value,
                          ),
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
                        final notifier = ref.read(appSettingsProvider.notifier);
                        runStorageAction(
                          context,
                          () => notifier.setSubtitleLanguage(
                            value == 'None' ? null : value,
                          ),
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
                      subtitle: 'Use the experimental MediaForge playback engine instead of the default player. Applies to the next video you open.',
                      icon: Icons.science_outlined,
                      value: s.useMediaForgePlayer,
                      onChanged: (value) => runStorageAction(
                        context,
                        () => ref
                            .read(appSettingsProvider.notifier)
                            .setUseMediaForgePlayer(value),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'Experimental MediaForge settings',
            subtitle: 'Defaults for future MediaForge sessions',
            children: [
              settings.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const SizedBox.shrink(),
                data: (s) => SettingsSelect<VideoEnhancementMode>(
                  title: 'Video Enhancement',
                  subtitle: mediaForgeVideoEnhancementCapabilityDescription(
                    enhancementCapabilities,
                  ),
                  icon: Icons.auto_awesome_outlined,
                  value: s.mediaForgeVideoEnhancementMode,
                  options: [
                    for (final mode in VideoEnhancementMode.values)
                      SelectOption(
                        value: mode,
                        label: mode.displayName,
                        enabled: isMediaForgeVideoEnhancementModeSupported(
                          mode: mode,
                          capabilities: enhancementCapabilities,
                        ),
                      ),
                  ],
                  onChanged: (value) => runStorageAction(
                    context,
                    () => ref
                        .read(appSettingsProvider.notifier)
                        .setMediaForgeVideoEnhancementMode(value),
                  ),
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
                          hint: 'Play a torrent and its downloaded parts will be kept here.',
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
    required this.clearing,
  });
  final PlaybackCacheSummary summary;
  final ValueChanged<int> onLimit;
  final VoidCallback onClear;
  final bool clearing;

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
          leading: clearing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined),
          title: Text(
            clearing ? 'Clearing cached data…' : 'Clear all cached data',
          ),
          onTap: clearing ? null : onClear,
        ),
      ],
    );
  }
}
