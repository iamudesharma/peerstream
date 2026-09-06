import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/watch_progress.dart';

WatchEntry entry({
  String key = 'movie/1',
  int positionMs = 60000,
  int durationMs = 600000,
  DateTime? updatedAt,
}) {
  return WatchEntry(
    key: key,
    media: const MediaRef(id: 1, type: MediaType.movie),
    title: 'Title $key',
    sourceId: 'source-$key',
    providerName: 'Provider',
    sourceUri: 'magnet:?xt=urn:btih:$key',
    inputType: 'magnet',
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt ?? DateTime.fromMillisecondsSinceEpoch(1000),
  );
}

void main() {
  test('progress is position over duration', () {
    expect(entry(positionMs: 150000, durationMs: 600000).progress, 0.25);
  });

  test('progress is zero without duration', () {
    expect(entry(positionMs: 1000, durationMs: 0).progress, 0);
  });

  test('finished at 95 percent or within final 30 seconds', () {
    expect(entry(positionMs: 570000, durationMs: 600000).isFinished, isTrue);
    expect(entry(positionMs: 575000, durationMs: 600000).isFinished, isTrue);
    expect(entry(positionMs: 300000, durationMs: 600000).isFinished, isFalse);
  });

  test('trivial below 30 seconds and 5 percent', () {
    expect(entry(positionMs: 10000, durationMs: 600000).isTrivial, isTrue);
    expect(entry(positionMs: 60000, durationMs: 600000).isTrivial, isFalse);
    expect(entry(positionMs: 10000, durationMs: 100000).isTrivial, isFalse);
  });

  test('normalize drops finished and trivial entries', () {
    final normalized = normalizeWatchHistory([
      entry(key: 'movie/2', positionMs: 590000, durationMs: 600000),
      entry(key: 'movie/3', positionMs: 1000, durationMs: 600000),
      entry(key: 'movie/4'),
    ]);
    expect(normalized.map((item) => item.key), ['movie/4']);
  });

  test('normalize keeps latest entry per key sorted by recency', () {
    final normalized = normalizeWatchHistory([
      entry(
        key: 'movie/2',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
      entry(
        key: 'movie/3',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      ),
      entry(
        key: 'movie/2',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]);
    expect(normalized.map((item) => item.key), ['movie/3', 'movie/2']);
  });

  test('episode keys include season and episode', () {
    expect(
      watchKey(const MediaRef(id: 5, type: MediaType.tv), 1, 2),
      'tv/5/1/2',
    );
    expect(watchKey(const MediaRef(id: 5, type: MediaType.movie), 1, 2), 'movie/5');
  });

  test('json round trip preserves fields', () {
    final decoded = WatchEntry.fromJson(entry().toJson());
    expect(decoded, entry());
  });

  test('remaining label covers minutes and hours', () {
    expect(
      entry(positionMs: 540000, durationMs: 600000).remainingLabel(),
      '1 min left',
    );
    expect(
      entry(positionMs: 0, durationMs: 7200000).remainingLabel(),
      '2h left',
    );
  });

  test('timestamp formats minutes and hours', () {
    expect(formatWatchTimestamp(const Duration(seconds: 75)), '1:15');
    expect(
      formatWatchTimestamp(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
