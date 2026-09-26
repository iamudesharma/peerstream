import 'package:test/test.dart';
import 'package:peerstream/services/streaming/http_range.dart';
import 'package:peerstream/services/streaming/piece_scheduler.dart';

void main() {
  group('parseHttpRangeHeader', () {
    test('null and empty mean full file', () {
      expect(parseHttpRangeHeader(null), isNull);
      expect(parseHttpRangeHeader(''), isNull);
      expect(parseHttpRangeHeader('  '), isNull);
    });

    test('parses closed, open-ended, and suffix forms', () {
      expect(parseHttpRangeHeader('bytes=0-1023')?.start, 0);
      expect(parseHttpRangeHeader('bytes=0-1023')?.end, 1023);
      final open = parseHttpRangeHeader('bytes=1024-')!;
      expect(open.start, 1024);
      expect(open.end, isNull);
      final suffix = parseHttpRangeHeader('bytes=-500')!;
      expect(suffix.isSuffix, isTrue);
      expect(suffix.end, 500);
    });

    test('honors only the first range of a multipart value', () {
      final r = parseHttpRangeHeader('bytes=0-99, 200-299')!;
      expect(r.start, 0);
      expect(r.end, 99);
    });

    test('round-trips through resolveHttpRange', () {
      const size = 1000;
      final r = resolveHttpRange(parseHttpRangeHeader('bytes=200-'), size);
      expect((r.start, r.end), (200, 999));
      expect(r.isPartial, isTrue);
      final suffix = resolveHttpRange(parseHttpRangeHeader('bytes=-100'), size);
      expect((suffix.start, suffix.end), (900, 999));
      expect(
        resolveHttpRange(
          parseHttpRangeHeader('bytes=9999-'),
          size,
        ).isSatisfiable,
        isFalse,
      );
    });
  });

  group('Range → piece mapping drives priorities', () {
    const pieceLen = 512 * 1024;
    const fileSize = 100 * 1024 * 1024;

    test('player probe at byte 0 maps to the first piece (critical)', () {
      final resolved = resolveHttpRange(
        parseHttpRangeHeader('bytes=0-'),
        fileSize,
      );
      final pieces = byteRangeToPieces(
        rangeStart: resolved.start,
        rangeEnd: resolved.start,
        fileOffset: 0,
        pieceLength: pieceLen,
        startPiece: 0,
        endPiece: 199,
      );
      final window = schedulerTiers(
        targetPiece: pieces.startPiece,
        startPiece: 0,
        endPiece: 199,
        pieceLength: pieceLen,
        bitrateBps: 800000,
      );
      expect(window.tierOf(pieces.startPiece), PieceTier.critical);
    });

    test('seek to the middle re-targets the window', () {
      final before = schedulerTiers(
        targetPiece: 5,
        startPiece: 0,
        endPiece: 199,
        pieceLength: pieceLen,
        bitrateBps: 800000,
      );
      final after = schedulerTiers(
        targetPiece: 100,
        startPiece: 0,
        endPiece: 199,
        pieceLength: pieceLen,
        bitrateBps: 800000,
      );
      expect(before.tierOf(100), PieceTier.background);
      expect(after.tierOf(100), PieceTier.critical);
      expect(after.tierOf(5), PieceTier.background);
    });

    test('cached target is critical without reviving old playback work', () {
      final w = schedulerTiers(
        targetPiece: 50,
        startPiece: 0,
        endPiece: 199,
        pieceLength: pieceLen,
        bitrateBps: 800000,
      );
      expect(w.startPiece, 50);
      expect(w.tierOf(50), PieceTier.critical);
      expect(w.tierOf(49), PieceTier.background);
    });

    test('startup container probes preserve a pending resume window', () {
      // media_kit asks for the head before it sends the real Range at the
      // restored position. The head must be served without clearing the
      // already-dispatched resume work.
      expect(
        shouldPreserveStartupResumeWindow(
          hasPendingResume: true,
          requestPiece: 0,
          startPiece: 0,
          resumeTargetPiece: 44,
        ),
        isTrue,
      );
      expect(
        shouldPreserveStartupResumeWindow(
          hasPendingResume: true,
          requestPiece: 44,
          startPiece: 0,
          resumeTargetPiece: 44,
        ),
        isTrue,
      );
      expect(
        shouldPreserveStartupResumeWindow(
          hasPendingResume: true,
          requestPiece: 20,
          startPiece: 0,
          resumeTargetPiece: 44,
        ),
        isFalse,
      );
      expect(
        shouldPreserveStartupResumeWindow(
          hasPendingResume: false,
          requestPiece: 0,
          startPiece: 0,
          resumeTargetPiece: 44,
        ),
        isFalse,
      );
    });
  });
}
