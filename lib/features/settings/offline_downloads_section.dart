import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/widgets/settings_widgets.dart';
import '../../providers/app_providers.dart';
import '../../services/streaming/offline_download.dart';

class OfflineDownloadsSection extends ConsumerWidget {
  const OfflineDownloadsSection({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      title: 'Offline saves',
      subtitle: 'Protected saves count against your storage limit. Transfers pause during playback.',
      children: [
        ValueListenableBuilder<OfflineJob?>(
          valueListenable: service.offline.state,
          builder: (context, job, _) {
            if (job == null) {
              return const ListTile(
                title: Text(
                  'Save a torrent from its source menu to watch offline.',
                ),
              );
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
                            'Received ${formatBytes(job.bytes)} · selected file ${formatBytes(job.total)}',
                          OfflinePhase.paused => 'Paused',
                          OfflinePhase.complete => 'Verified and ready offline',
                          OfflinePhase.error =>
                            'Save failed. Retry or check storage.',
                        },
                  ),
                ),
                if (job.phase == OfflinePhase.preparing ||
                    job.phase == OfflinePhase.downloading)
                  const LinearProgressIndicator(),
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
                  for (final entry in entries.where((e) => e.pinned))
                    ListTile(
                      leading: Icon(
                        entry.complete
                            ? Icons.offline_pin
                            : Icons.download_outlined,
                      ),
                      title: Text(entry.source.name),
                      subtitle: Text(
                        entry.complete
                            ? 'Verified offline · ${formatBytes(entry.file.size)}'
                            : 'Partial save · selected file ${formatBytes(entry.file.size)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Offline save actions',
                        onSelected: (value) => action(() async {
                          if (value == 'resume') {
                            await service.saveOffline(entry.source);
                          } else {
                            await ref
                                .read(playbackCacheProvider)
                                .setPinned(entry.cacheKey, false);
                          }
                        }),
                        itemBuilder: (_) => [
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
