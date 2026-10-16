import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/media_item.dart';
import 'playback_experience.dart';

class QueueItem {
  const QueueItem({
    required this.media,
    required this.title,
    this.season,
    this.episode,
  });
  final MediaRef media;
  final String title;
  final int? season;
  final int? episode;
  String get key => '${media.routeKey}:${season ?? 0}:${episode ?? 0}';
  String get route => Uri(
    path: '/sources/${media.routeKey}',
    queryParameters: {
      if (season != null) 'season': '$season',
      if (episode != null) 'episode': '$episode',
    },
  ).toString();
  Map<String, dynamic> toJson() => {
    'id': media.id,
    'type': media.type.name,
    'title': title,
    'season': season,
    'episode': episode,
  };
  factory QueueItem.fromJson(Map data) => QueueItem(
    media: MediaRef(
      id: data['id'] as int,
      type: MediaType.parse(data['type'] as String),
    ),
    title: data['title'] as String,
    season: data['season'] as int?,
    episode: data['episode'] as int?,
  );
}

class PlaybackQueue extends AsyncNotifier<List<QueueItem>> {
  PlaybackQueue({PlaybackExperience? store})
    : _store = store ?? playbackExperience;
  final PlaybackExperience _store;
  Future<void> _tail = Future.value();
  @override
  Future<List<QueueItem>> build() async {
    await _store.load();
    if (_store.loadError != null) throw StateError('Queue storage unavailable');
    final rows = _store.section('queue')['items'] as List? ?? [];
    return rows.whereType<Map>().map(QueueItem.fromJson).take(100).toList();
  }

  Future<void> _change(List<QueueItem> Function(List<QueueItem>) action) {
    final next = _tail.then((_) async {
      final current = state.value ?? await future;
      final items = action(List.of(current));
      await _store.update(
        (data) =>
            data['queue'] = {'items': items.map((e) => e.toJson()).toList()},
      );
      state = AsyncData(items);
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> add(QueueItem item) => _change((items) {
    if (items.any((i) => i.key == item.key)) return items;
    if (items.length >= 100) throw StateError('Queue is full');
    return [...items, item];
  });
  Future<void> remove(String key) =>
      _change((items) => items.where((i) => i.key != key).toList());
  Future<void> reorder(int from, int to) => _change((items) {
    final item = items.removeAt(from);
    items.insert(to, item);
    return items;
  });
}

final playbackQueueProvider =
    AsyncNotifierProvider<PlaybackQueue, List<QueueItem>>(PlaybackQueue.new);
