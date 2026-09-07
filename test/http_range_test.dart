import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/streaming/http_range.dart';
import 'package:peerstream/services/streaming/playback_config.dart';

void main() {
  group('HTTP range semantics (RFC 9110)', () {
    const size = 1000;
    test('no range returns full file 200', () {
      final r = resolveHttpRange(null, size);
      expect(r.isSatisfiable, isTrue);
      expect(r.isPartial, isFalse);
      expect((r.start, r.end), (0, 999));
    });
    test('suffix bytes=-100 returns tail', () {
      final r = resolveHttpRange(const HttpRangeRequest(isSuffix: true, end: 100), size);
      expect((r.start, r.end), (900, 999));
    });
    test('suffix larger than file clamps to full file', () {
      final r = resolveHttpRange(const HttpRangeRequest(isSuffix: true, end: 5000), size);
      expect((r.start, r.end), (0, 999));
    });
    test('suffix length 0 is unsatisfiable (416)', () {
      final r = resolveHttpRange(const HttpRangeRequest(isSuffix: true, end: 0), size);
      expect(r.isSatisfiable, isFalse);
    });
    test('open-ended bytes=200- runs to EOF', () {
      final r = resolveHttpRange(const HttpRangeRequest(start: 200), size);
      expect((r.start, r.end), (200, 999));
      expect(r.isPartial, isTrue);
    });
    test('clamped end bytes=800-5000 satisfies prefix', () {
      final r = resolveHttpRange(const HttpRangeRequest(start: 800, end: 5000), size);
      expect((r.start, r.end), (800, 999));
    });
    test('start beyond EOF is 416, not a clamp', () {
      final r = resolveHttpRange(const HttpRangeRequest(start: 1000, end: 1500), size);
      expect(r.isSatisfiable, isFalse);
    });
    test('end before start is 416', () {
      final r = resolveHttpRange(const HttpRangeRequest(start: 500, end: 100), size);
      expect(r.isSatisfiable, isFalse);
    });
  });

  group('seek vs probe', () {
    const bigFile = 2 * 1024 * 1024 * 1024;
    const piece = 1024 * 1024;
    test('HEAD never triggers seek', () {
      expect(
        shouldTriggerSeek(isHead: true, rangeStart: 500000000, fileSize: bigFile, pieceLength: piece, currentHead: 1000),
        isFalse,
      );
    });
    test('tail metadata probe never seeks', () {
      expect(
        shouldTriggerSeek(isHead: false, rangeStart: bigFile - 1024, fileSize: bigFile, pieceLength: piece, currentHead: 1000),
        isFalse,
      );
    });
    test('distant GET seeks, nearby re-read does not', () {
      expect(
        shouldTriggerSeek(isHead: false, rangeStart: 500000000, fileSize: bigFile, pieceLength: piece, currentHead: 1000),
        isTrue,
      );
      expect(
        shouldTriggerSeek(isHead: false, rangeStart: 2000, fileSize: bigFile, pieceLength: piece, currentHead: 1000),
        isFalse,
      );
    });
  });

  group('player profiles and timeouts', () {
    test('direct, torrent, and cache use separate tunings', () {
      expect(PlayerProfile.direct.networkTimeoutSecs, isNot(PlayerProfile.torrent.networkTimeoutSecs));
      expect(PlayerProfile.cache.demuxerMaxBytes, isNot(PlayerProfile.direct.demuxerMaxBytes));
      // cache-secs must dominate readahead (mpv semantics).
      for (final p in [PlayerProfile.direct, PlayerProfile.torrent, PlayerProfile.cache]) {
        expect(int.parse(p.cacheSecs) >= int.parse(p.readaheadSecs), isTrue);
      }
      expect(PlayerProfile.forOrigin(true, false), PlayerProfile.cache);
      expect(PlayerProfile.forOrigin(false, true), PlayerProfile.direct);
      expect(PlayerProfile.forOrigin(false, false), PlayerProfile.torrent);
    });
    test('native piece wait matches player network timeout', () {
      expect(StreamingTimeouts.nativePieceWait, StreamingTimeouts.playerNetworkTimeout);
    });
  });
}
