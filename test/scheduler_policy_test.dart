import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

void main() {
  group('observedByteForTime', () {
    test('interpolates between anchors', () {
      const points = [
        TimeBytePoint(positionMs: 60000, byteOffset: 100000),
        TimeBytePoint(positionMs: 120000, byteOffset: 300000),
      ];
      expect(
        observedByteForTime(points, positionMs: 90000, fileSize: 1000000),
        200000,
      );
      expect(
        observedByteForTime(points, positionMs: 60000, fileSize: 1000000),
        100000,
      );
    });

    test('returns null outside the observed range', () {
      const points = [
        TimeBytePoint(positionMs: 60000, byteOffset: 100000),
        TimeBytePoint(positionMs: 120000, byteOffset: 300000),
      ];
      expect(
        observedByteForTime(points, positionMs: 30000, fileSize: 1000000),
        isNull,
      );
      expect(
        observedByteForTime(points, positionMs: 300000, fileSize: 1000000),
        isNull,
      );
      expect(
        observedByteForTime(const [], positionMs: 60000, fileSize: 1000000),
        isNull,
      );
    });

    test('rejects non-monotonic anchors', () {
      const points = [
        TimeBytePoint(positionMs: 60000, byteOffset: 300000),
        TimeBytePoint(positionMs: 120000, byteOffset: 100000),
      ];
      expect(
        observedByteForTime(points, positionMs: 90000, fileSize: 1000000),
        isNull,
      );
    });

    test('extrapolates a bounded distance past the last anchor', () {
      const points = [
        TimeBytePoint(positionMs: 60000, byteOffset: 100000),
        TimeBytePoint(positionMs: 120000, byteOffset: 300000),
      ];
      // 10s past the last anchor at the same local slope (~3.33 B/ms).
      expect(
        observedByteForTime(points, positionMs: 130000, fileSize: 1000000),
        333333,
      );
    });
  });

  group('mergeTimeBytePoint', () {
    test('keeps points sorted and replaces nearby observations', () {
      final merged = mergeTimeBytePoint(
        const [TimeBytePoint(positionMs: 60000, byteOffset: 100000)],
        const TimeBytePoint(positionMs: 70000, byteOffset: 120000),
        fileSize: 1000000,
      );
      expect(merged, hasLength(1));
      expect(merged.single.positionMs, 70000);
      expect(merged.single.byteOffset, 120000);
    });

    test('caps the map while keeping coverage spread', () {
      var points = <TimeBytePoint>[];
      for (var i = 1; i <= 40; i++) {
        points = mergeTimeBytePoint(
          points,
          TimeBytePoint(positionMs: i * 600000, byteOffset: i * 50000000),
          fileSize: 2000000000,
          maxPoints: 8,
        );
      }
      expect(points, hasLength(8));
      expect(points.first.positionMs, lessThan(points.last.positionMs));
    });

    test('ignores invalid observations', () {
      const existing = [TimeBytePoint(positionMs: 60000, byteOffset: 100000)];
      expect(
        mergeTimeBytePoint(
          existing,
          const TimeBytePoint(positionMs: 0, byteOffset: 100),
          fileSize: 1000000,
        ),
        existing,
      );
      expect(
        mergeTimeBytePoint(
          existing,
          const TimeBytePoint(positionMs: 60000, byteOffset: 0),
          fileSize: 1000000,
        ),
        existing,
      );
    });
  });

  group('observedBitrateBps', () {
    test('uses the local segment when bracketing', () {
      const points = [
        TimeBytePoint(positionMs: 60000, byteOffset: 300000),
        TimeBytePoint(positionMs: 120000, byteOffset: 900000),
      ];
      expect(
        observedBitrateBps(
          points,
          positionMs: 90000,
          durationMs: 600000,
          fileSize: 1000000,
        ),
        10000,
      );
    });

    test('falls back to the file average without anchors', () {
      expect(
        observedBitrateBps(
          const [],
          positionMs: 90000,
          durationMs: 100000,
          fileSize: 1000000,
        ),
        10000,
      );
    });
  });

  group('adaptiveWindowBytes', () {
    const bitrate = 200000; // 200 KB/s

    test('startup and starving sessions fetch a deep margin', () {
      final window = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 0,
        downloadRateBps: (bitrate * 1.5).round(),
        peers: 10,
      );
      expect(window, (bitrate * 60).round());
    });

    test('well-buffered playback keeps a small margin', () {
      final window = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: (bitrate * 1.5).round(),
        peers: 10,
      );
      expect(window, (bitrate * 15).round());
    });

    test('a rate barely keeping up widens the window', () {
      final tight = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: bitrate,
        peers: 10,
      );
      expect(tight, (bitrate * 22.5).round());
    });

    test('a slow swarm widens the window, a fast one narrows it', () {
      final slow = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: (bitrate * 0.8).round(),
        peers: 10,
      );
      final fast = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: bitrate * 5,
        peers: 10,
      );
      expect(slow, greaterThan(fast));
    });

    test('thin swarms get extra margin and the result is bounded', () {
      final thin = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: bitrate,
        peers: 2,
      );
      final unknown = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 90000,
        downloadRateBps: bitrate,
        peers: 0,
      );
      expect(thin, greaterThan(unknown));
      final extreme = adaptiveWindowBytes(
        bitrateBps: bitrate,
        bufferedAheadMs: 0,
        downloadRateBps: (bitrate * 0.1).round(),
        peers: 1,
      );
      expect(extreme, lessThanOrEqualTo((bitrate * 90).round()));
    });

    test('returns zero without a usable bitrate', () {
      expect(
        adaptiveWindowBytes(
          bitrateBps: 0,
          bufferedAheadMs: 0,
          downloadRateBps: 0,
          peers: 0,
        ),
        0,
      );
    });
  });
}
