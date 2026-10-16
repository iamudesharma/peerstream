import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/video/desktop_video.dart';
import '../player/external_player_screen.dart';

import '../../core/format.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';
import '../../services/streaming/offline_download.dart';
import '../../services/playback/torrent_cache_identity.dart';
import '../../models/torrent_models.dart';

class OfflineDownloadsSection extends ConsumerStatefulWidget {
  const OfflineDownloadsSection({super.key});
  @override
  ConsumerState<OfflineDownloadsSection> createState() =>
      _OfflineDownloadsSectionState();
}

class _OfflineDownloadsSectionState
    extends ConsumerState<OfflineDownloadsSection> {
  OfflinePhase? _lastPhase;
  late final ValueNotifier<OfflineJob?> _jobs;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _jobs = ref.read(streamingServiceProvider).offline.state;
    _jobs.addListener(_changed);
    ref
        .read(streamingServiceProvider)
        .offline
        .restoreIntent()
        .catchError((Object _) {});
  }

  void _changed() {
    final phase = _jobs.value?.phase;
    if (phase == _lastPhase) return;
    _lastPhase = phase;
    if (phase == OfflinePhase.complete ||
        phase == OfflinePhase.paused ||
        phase == OfflinePhase.error ||
        phase == null) {
      ref.invalidate(playbackCacheEntriesProvider);
      ref.invalidate(playbackCacheSummaryProvider);
    }
  }

  @override
  void dispose() {
    _jobs.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.read(streamingServiceProvider);
    Future<void> action(Future<void> Function() run) async {
      try {
        await run();
        ref.invalidate(playbackCacheEntriesProvider);
        ref.invalidate(playbackCacheSummaryProvider);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not update the offline save. Check storage and retry.',
              ),
            ),
          );
        }
      }
    }

    return SettingsSection(
      title: 'Video downloads',
      subtitle: 'Keep PeerStream open while downloading. Downloads use your selected storage drive and pause during playback.',
      children: [
        ValueListenableBuilder<OfflineJob?>(
          valueListenable: service.offline.state,
          builder: (context, job, _) {
            if (job == null) {
              return const ListTile(
                title: Text(
                  'Choose Download on a video source to get started.',
                ),
              );
            }
            if (job.phase == OfflinePhase.complete) {
              return const SizedBox.shrink();
            }
            return Column(
              children: [
                ListTile(
                  title: Text(job.source.name),
                  subtitle: Text(
                    job.message ??
                        switch (job.phase) {
                          OfflinePhase.preparing => 'Finding the selected file',
                          OfflinePhase.downloading =>
                            '${job.total > 0 ? '${(job.bytes * 100 / job.total).clamp(0, 100).toStringAsFixed(0)}% · ' : ''}${formatBytes(job.bytes)}${job.total > 0 ? ' of ${formatBytes(job.total)}' : ''}',
                          OfflinePhase.paused => 'Paused',
                          OfflinePhase.complete =>
                            'Downloaded and ready offline',
                          OfflinePhase.error =>
                            'Save failed. Retry or check storage.',
                        },
                  ),
                ),
                if (job.phase == OfflinePhase.preparing ||
                    job.phase == OfflinePhase.downloading)
                  LinearProgressIndicator(
                    value: job.total > 0
                        ? (job.bytes / job.total).clamp(0, 1)
                        : null,
                  ),
                Wrap(
                  children: [
                    if (job.phase == OfflinePhase.downloading ||
                        job.phase == OfflinePhase.preparing)
                      TextButton(
                        onPressed: () => action(() => service.offline.pause()),
                        child: const Text('Pause'),
                      ),
                    if (job.phase == OfflinePhase.paused ||
                        job.phase == OfflinePhase.error)
                      TextButton(
                        onPressed: () => action(
                          () => service.offline.resume(
                            playbackActive: service.playbackActive,
                          ),
                        ),
                        child: const Text('Resume'),
                      ),
                    if (job.phase != OfflinePhase.complete)
                      TextButton(
                        onPressed: () => action(service.offline.cancel),
                        child: const Text('Cancel save'),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
        ref
            .watch(playbackCacheEntriesProvider)
            .when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const Text('Saved video list unavailable'),
              data: (entries) => Column(
                children: [
                  for (final entry in entries.where(
                    (e) =>
                        e.pinned &&
                        !(_jobs.value != null &&
                            _jobs.value!.phase != OfflinePhase.complete &&
                            e.cacheKey == torrentCacheKey(_jobs.value!.source)),
                  ))
                    ListTile(
                      leading: Icon(
                        entry.complete
                            ? Icons.offline_pin
                            : Icons.download_outlined,
                      ),
                      title: Text(entry.source.name),
                      subtitle: Text(
                        entry.complete
                            ? '${entry.source.inputType == TorrentInputType.directUrl ? 'Downloaded' : 'Verified offline'} · ${formatBytes(entry.file.size)}'
                            : 'Partial save · selected file ${formatBytes(entry.file.size)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Offline save actions',
                        onSelected: (value) => action(() async {
                          if (value == 'resume') {
                            await service.saveOffline(entry.source);
                          } else if (value == 'play') {
                            context.push(
                              '/player/${entry.source.content.routeKey}?source=${Uri.encodeQueryComponent(entry.source.id)}',
                              extra: entry.source,
                            );
                          } else if (value == 'external') {
                            final player = await chooseExternalVideoPlayer(
                              context,
                            );
                            if (player != null && context.mounted) {
                              context.push(
                                '/external-player',
                                extra: ExternalPlayerRequest(
                                  entry.source,
                                  player,
                                ),
                              );
                            }
                          } else if (value == 'export') {
                            if (_busy) return;
                            setState(() => _busy = true);
                            try {
                              final local = await ref
                                  .read(playbackCacheProvider)
                                  .completeFile(entry.source);
                              if (local == null) {
                                throw StateError('Saved file unavailable');
                              }
                              final saved = await const DesktopVideo()
                                  .exportFile(local.filePath, local.file.name);
                              if (saved != null && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Video file saved.'),
                                  ),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          } else {
                            await ref
                                .read(playbackCacheProvider)
                                .setPinned(entry.cacheKey, false);
                          }
                        }),
                        enabled: !_busy,
                        itemBuilder: (_) => [
                          if (entry.complete)
                            const PopupMenuItem(
                              value: 'play',
                              child: Text('Play downloaded video'),
                            ),
                          if (entry.complete && const DesktopVideo().supported)
                            const PopupMenuItem(
                              value: 'external',
                              child: Text('Open in external player…'),
                            ),
                          if (entry.complete && const DesktopVideo().supported)
                            const PopupMenuItem(
                              value: 'export',
                              child: Text('Save file as…'),
                            ),
                          if (!entry.complete)
                            const PopupMenuItem(
                              value: 'resume',
                              child: Text('Resume save'),
                            ),
                          const PopupMenuItem(
                            value: 'unprotect',
                            child: Text('Allow automatic removal'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}
