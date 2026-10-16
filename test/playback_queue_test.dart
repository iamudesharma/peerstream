import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/services/experience/playback_experience.dart';
import 'package:peerstream/services/experience/playback_queue.dart';

void main() {
  test('queue deduplicates media, preserves order, reorders with adjusted destination and persists removal', () async {
    Map<String, dynamic> saved = {};
    final journal = PlaybackExperience(
      read: () async => {},
      write: (value) async {
        saved = Map.of(value);
      },
    );
    final container = ProviderContainer(
      overrides: [
        playbackQueueProvider.overrideWith(() => PlaybackQueue(store: journal)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(playbackQueueProvider.future);
    final queue = container.read(playbackQueueProvider.notifier);
    for (final id in [1, 2, 3, 1]) {
      await queue.add(
        QueueItem(
          media: MediaRef(id: id, type: MediaType.movie),
          title: '$id',
        ),
      );
    }
    await queue.reorder(0, 2);
    expect(
      container.read(playbackQueueProvider).value!.map((i) => i.media.id),
      [2, 3, 1],
    );
    await queue.remove('movie/3:0:0');
    expect(((saved['queue'] as Map)['items'] as List).length, 2);
  });
}
