import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/streaming/piece_scheduler.dart';

void main() {
  group('byteRangeToPieces', () {
    test('maps file bytes to torrent pieces', () {
      // file at torrent offset 0, 1MB pieces.
      const pieceLen = 1024 * 1024;
      final r = byteRangeToPieces(
        rangeStart: 0,
        rangeEnd: 512 * 1024 - 1,
        fileOffset: 0,
        pieceLength: pieceLen,
        startPiece: 10,
        endPiece: 20,
      );
      expect(r.startPiece, 10);
      expect(r.endPiece, 10);
    });

    test('spans multiple pieces and clamps to file span', () {
      const pieceLen = 256 * 1024;
      final r = byteRangeToPieces(
        rangeStart: 200 * 1024,
        rangeEnd: 600 * 1024,
        fileOffset: 0,
        pieceLength: pieceLen,
        startPiece: 0,
        endPiece: 100,
      );
      expect(r.startPiece, 0);
      expect(r.endPiece, 2);
    });

    test('accounts for file offset inside the torrent', () {
      const pieceLen = 1024 * 1024;
      // File starts 0.5MB into piece 5.
      final r = byteRangeToPieces(
        rangeStart: 0,
        rangeEnd: 100,
        fileOffset: 512 * 1024,
        pieceLength: pieceLen,
        startPiece: 0,
        endPiece: 10,
      );
      expect(r.startPiece, 0);
    });

    test('clamps out-of-span ranges', () {
      final r = byteRangeToPieces(
        rangeStart: 0,
        rangeEnd: 1 << 30,
        fileOffset: 0,
        pieceLength: 1024 * 1024,
        startPiece: 3,
        endPiece: 5,
      );
      expect(r.endPiece, 5);
    });
  });

  group('estimateBitrateBps', () {
    test('uses duration when available', () {
      expect(
        estimateBitrateBps(fileSize: 1000000, durationMs: 100000),
        10000,
      );
    });

    test('falls back to size-based guess', () {
      final episode = estimateBitrateBps(fileSize: 300 * 1024 * 1024);
      final movie = estimateBitrateBps(fileSize: 2 * 1024 * 1024 * 1024);
      expect(episode, greaterThan(0));
      expect(movie, greaterThan(episode));
    });

    test('returns zero without file size', () {
      expect(estimateBitrateBps(fileSize: 0), 0);
    });
  });

  group('schedulerTiers', () {
    test('critical covers the blocked piece first', () {
      final w = schedulerTiers(
        targetPiece: 10,
        startPiece: 0,
        endPiece: 100,
        pieceLength: 1024 * 1024,
        bitrateBps: 500000,
      );
      expect(w.startPiece, lessThanOrEqualTo(10));
      expect(w.criticalEnd, greaterThanOrEqualTo(10));
      expect(w.urgentEnd, greaterThanOrEqualTo(w.criticalEnd));
      expect(w.endPiece, greaterThanOrEqualTo(w.urgentEnd));
      expect(w.tierOf(10), PieceTier.critical);
      expect(w.tierOf(w.endPiece + 1), PieceTier.background);
    });

    test('large pieces yield smaller piece windows than small pieces', () {
      final small = schedulerTiers(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 1000,
        pieceLength: 256 * 1024,
        bitrateBps: 1000000,
      );
      final large = schedulerTiers(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 1000,
        pieceLength: 4 * 1024 * 1024,
        bitrateBps: 1000000,
      );
      expect(small.totalPieces, greaterThan(large.totalPieces));
    });

    test('slow swarms get deeper windows than fast swarms', () {
      final slow = adaptiveLookaheadPieces(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 1000,
        pieceLength: 1024 * 1024,
        bitrateBps: 500000,
        downloadRateBps: 100000,
        peers: 10,
      );
      final fast = adaptiveLookaheadPieces(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 1000,
        pieceLength: 1024 * 1024,
        bitrateBps: 500000,
        downloadRateBps: 5000000,
        peers: 10,
      );
      expect(slow, greaterThan(fast));
    });

    test('window never exceeds the file span', () {
      final w = schedulerTiers(
        targetPiece: 98,
        startPiece: 0,
        endPiece: 100,
        pieceLength: 256 * 1024,
        bitrateBps: 500000,
      );
      expect(w.endPiece, lessThanOrEqualTo(100));
      expect(w.totalPieces, lessThanOrEqualTo(101));
    });

    test('clamps to [4, 64] pieces', () {
      final tiny = adaptiveLookaheadPieces(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 1000,
        pieceLength: 16 * 1024 * 1024,
        bitrateBps: 200000,
        peers: 50,
        downloadRateBps: 100 * 1024 * 1024,
      );
      expect(tiny, greaterThanOrEqualTo(4));
      final huge = adaptiveLookaheadPieces(
        targetPiece: 0,
        startPiece: 0,
        endPiece: 10000,
        pieceLength: 64 * 1024,
        bitrateBps: 5000000,
        downloadRateBps: 1000,
        peers: 1,
      );
      expect(huge, lessThanOrEqualTo(64));
    });
  });

  group('deadlines and startup', () {
    test('deadline step scales with piece duration and clamps', () {
      final smallStep = pieceDeadlineStepMs(
        pieceLength: 256 * 1024,
        bitrateBps: 2000000,
      );
      final largeStep = pieceDeadlineStepMs(
        pieceLength: 8 * 1024 * 1024,
        bitrateBps: 500000,
      );
      expect(smallStep, lessThanOrEqualTo(largeStep));
      expect(smallStep, greaterThanOrEqualTo(40));
      expect(largeStep, lessThanOrEqualTo(250));
    });

    test('critical startup stays within 1..5 pieces', () {
      expect(
        criticalStartupPieces(
          pieceLength: 256 * 1024,
          bitrateBps: 500000,
        ),
        inInclusiveRange(1, 5),
      );
      expect(
        criticalStartupPieces(
          pieceLength: 4 * 1024 * 1024,
          bitrateBps: 3000000,
        ),
        inInclusiveRange(1, 5),
      );
    });
  });
}
