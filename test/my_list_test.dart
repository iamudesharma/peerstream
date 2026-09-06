import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/saved_item.dart';
import 'package:peerstream/services/mylist/my_list_store_memory.dart'
    as memory_store;

SavedItem saved({
  int id = 1,
  MediaType type = MediaType.movie,
  String? title,
  DateTime? addedAt,
}) {
  final media = MediaRef(id: id, type: type);
  return SavedItem(
    key: media.routeKey,
    media: media,
    title: title ?? 'Title $id',
    overview: 'Overview $id',
    posterPath: '/poster$id.jpg',
    backdropPath: '/backdrop$id.jpg',
    releaseDate: '2024-01-0$id',
    rating: 7.5,
    addedAt: addedAt ?? DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

void main() {
  test('toMediaItem preserves display fields', () {
    final item = saved().toMediaItem();
    expect(item.id, 1);
    expect(item.type, MediaType.movie);
    expect(item.title, 'Title 1');
    expect(item.overview, 'Overview 1');
    expect(item.posterPath, '/poster1.jpg');
    expect(item.backdropPath, '/backdrop1.jpg');
    expect(item.releaseDate, '2024-01-01');
    expect(item.rating, 7.5);
  });

  test('fromMediaItem round trips through toMediaItem', () {
    const media = MediaItem(
      id: 42,
      type: MediaType.tv,
      title: 'Series',
      overview: 'A show',
      posterPath: '/p.jpg',
      rating: 8.2,
    );
    final item = SavedItem.fromMediaItem(media).toMediaItem();
    expect(item.id, 42);
    expect(item.type, MediaType.tv);
    expect(item.title, 'Series');
    expect(item.posterPath, '/p.jpg');
    expect(item.rating, 8.2);
  });

  test('json round trip preserves fields', () {
    expect(SavedItem.fromJson(saved().toJson()), saved());
  });

  test('normalize dedupes by key keeping latest', () {
    final normalized = normalizeMyList([
      saved(id: 1, addedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
      saved(id: 2, addedAt: DateTime.fromMillisecondsSinceEpoch(3000)),
      saved(
        id: 1,
        title: 'Updated',
        addedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]);
    expect(normalized.map((item) => item.key), ['movie/2', 'movie/1']);
    expect(normalized.last.title, 'Updated');
  });

  test('normalize sorts newest first and caps at 100', () {
    final items = List.generate(
      myListMaxEntries + 5,
      (index) => saved(
        id: index,
        addedAt: DateTime.fromMillisecondsSinceEpoch(1000 + index),
      ),
    );
    final normalized = normalizeMyList(items);
    expect(normalized, hasLength(myListMaxEntries));
    expect(normalized.first.key, 'movie/${myListMaxEntries + 4}');
  });

  test('memory store round trip normalizes entries', () async {
    await memory_store.writeMyList(const []);
    expect(await memory_store.readMyList(), isEmpty);
    await memory_store.writeMyList([saved(id: 1), saved(id: 2)]);
    expect(await memory_store.readMyList(), hasLength(2));
    await memory_store.writeMyList(const []);
  });
}
