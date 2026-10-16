import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/experience/playback_queue.dart';

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});
  Future<void> _change(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save the queue. Check storage and retry.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Play queue')),
    body: ref
        .watch(playbackQueueProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) =>
              const Center(child: Text('Could not load the queue.')),
          data: (items) => items.isEmpty
              ? const Center(
                  child: Text('Add videos from the player settings.'),
                )
              : ReorderableListView.builder(
                  itemCount: items.length,
                  onReorderItem: (from, to) => _change(
                    context,
                    ref.read(playbackQueueProvider.notifier).reorder(from, to),
                  ),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      key: ValueKey(item.key),
                      title: Text(item.title),
                      subtitle: item.episode == null
                          ? null
                          : Text(
                              'Season ${item.season} · Episode ${item.episode}',
                            ),
                      leading: IconButton(
                        tooltip: 'Play queued video',
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () => context.push(item.route),
                      ),
                      trailing: Padding(
                        padding: const EdgeInsets.only(right: 48),
                        child: IconButton(
                          tooltip: 'Remove from queue',
                          icon: const Icon(Icons.close),
                          onPressed: () => _change(
                            context,
                            ref
                                .read(playbackQueueProvider.notifier)
                                .remove(item.key),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
  );
}
