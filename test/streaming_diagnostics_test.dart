import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/streaming/playback_session.dart';

void main() {
  group('PlaybackDiagnostics startup latencies', () {
    test('computes torrent, first-byte, and range→piece latencies', () {
      final d = PlaybackDiagnostics(sessionId: 1)
        ..sessionClaimedAt = DateTime(2026, 1, 1, 0, 0, 0)
        ..torrentAddedAt = DateTime(2026, 1, 1, 0, 0, 1)
        ..metadataAt = DateTime(2026, 1, 1, 0, 0, 3)
        ..firstRangeRequestAt = DateTime(2026, 1, 1, 0, 0, 4)
        ..firstPieceCompletedAt = DateTime(2026, 1, 1, 0, 0, 6)
        ..firstByteSentAt = DateTime(2026, 1, 1, 0, 0, 7)
        ..firstFrameAt = DateTime(2026, 1, 1, 0, 0, 9);
      expect(d.torrentStartupLatency?.inSeconds, 2);
      expect(d.rangeToPieceLatency?.inSeconds, 2);
      expect(d.timeToFirstHttpByte?.inSeconds, 7);
      expect(d.tapToFirstFrame?.inSeconds, 9);
      final map = d.toMap();
      expect(map['torrentStartupLatencyMs'], 2000);
      expect(map['rangeToPieceLatencyMs'], 2000);
      expect(map['timeToFirstHttpByteMs'], 7000);
      expect(map['tapToFirstFrameMs'], 9000);
      expect(d.startupSummary(), contains('tapToFirstFrame=9000ms'));
    });

    test('clamps cache-hit completions to zero instead of negative', () {
      final d = PlaybackDiagnostics(sessionId: 3)
        ..firstRangeRequestAt = DateTime(2026, 1, 1, 0, 0, 4)
        ..firstPieceCompletedAt = DateTime(2026, 1, 1, 0, 0, 3, 878);
      // Piece verified (resume cache) before the first Range arrived.
      expect(d.rangeToPieceLatency, Duration.zero);
      expect(d.toMap()['rangeToPieceLatencyMs'], 0);
    });

    test('returns null latencies when endpoints are missing', () {
      final d = PlaybackDiagnostics(sessionId: 2);
      expect(d.torrentStartupLatency, isNull);
      expect(d.timeToFirstHttpByte, isNull);
      expect(d.rangeToPieceLatency, isNull);
      expect(d.tapToFirstFrame, isNull);
    });

    test('seek latency latches and reports', () {
      final d = PlaybackDiagnostics(sessionId: 3);
      final start = DateTime(2026, 1, 1, 0, 0, 0);
      d.seekStarted(start);
      d.seekSettled(start.add(const Duration(milliseconds: 350)));
      expect(d.lastSeekLatencyMs, 350);
      expect(d.toMap()['seekLatencyMs'], 350);
    });

    test('rebuffer episodes accumulate duration', () {
      final d = PlaybackDiagnostics(sessionId: 4);
      final start = DateTime(2026, 1, 1, 0, 0, 0);
      d.rebufferStarted(start);
      d.rebufferEnded(start.add(const Duration(milliseconds: 1200)));
      expect(d.rebufferDurationMs, 1200);
      d.rebufferStarted(start.add(const Duration(seconds: 10)));
      d.rebufferEnded(start.add(const Duration(seconds: 10, milliseconds: 800)));
      expect(d.rebufferDurationMs, 2000);
    });
  });
}
