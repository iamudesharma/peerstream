import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/experience/playback_experience.dart';

void main() {
  test(
    'watched records survive history removal and failed writes are atomic',
    () async {
      var fail = false;
      final store = PlaybackExperience(
        read: () async => {},
        write: (_) async {
          if (fail) throw StateError('disk full');
        },
      );
      await store.markWatched('episode-1', 'series:1');
      expect(store.watchedMedia, contains('series:1'));
      fail = true;
      await expectLater(
        store.markWatched('movie-2', 'movie:2'),
        throwsStateError,
      );
      expect(store.watchedMedia, isNot(contains('movie:2')));
    },
  );
  test('a read failure never overwrites saved experience data', () async {
    var writes = 0;
    final journal = PlaybackExperience(
      read: () async => throw StateError('SSD disconnected'),
      write: (_) async {
        writes++;
      },
    );
    await journal.load();
    await expectLater(journal.observe('test', success: true), throwsStateError);
    expect(writes, 0);
  });
  test('recent failures eventually outweigh old successful starts', () async {
    final journal = PlaybackExperience(
      read: () async => {},
      write: (_) async {},
    );
    for (var i = 0; i < 25; i++) {
      await journal.observe('source', success: true, startupMs: 100);
    }
    for (var i = 0; i < 40; i++) {
      await journal.observe('source', success: false);
    }
    expect(journal.score('source'), lessThan(0));
  });

  test(
    'observations expire, failures are negative, unknown sources are neutral',
    () async {
      var now = DateTime.utc(2026, 10, 14);
      final store = PlaybackExperience(
        read: () async => {},
        write: (_) async {},
        now: () => now,
      );
      await store.load();
      expect(store.score('unknown'), 0);
      await store.observe('good', success: true, startupMs: 1000);
      await store.observe('bad', success: false);
      expect(store.score('good'), greaterThan(0));
      expect(store.score('bad'), lessThan(0));
      now = now.add(const Duration(days: 8));
      expect(store.score('good'), 0);
    },
  );
  test(
    'serialized journal updates retain both sections and cap source count',
    () async {
      Map<String, dynamic> saved = {};
      final store = PlaybackExperience(
        read: () async => {},
        write: (value) async {
          saved = Map.of(value);
        },
      );
      await Future.wait([
        store.update(
          (v) => v['timing'] = {
            'file': {'audioMs': 50},
          },
        ),
        store.observe('source', success: true),
      ]);
      expect(saved.keys, containsAll(['timing', 'reliability']));
      for (var i = 0; i < 140; i++) {
        await store.observe('$i', success: true);
      }
      expect((saved['reliability'] as Map).length, 128);
    },
  );
}
