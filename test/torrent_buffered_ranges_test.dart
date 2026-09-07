import 'package:flutter_test/flutter_test.dart';
import 'package:media_forge_player/media_forge_player.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/streaming/torrent_buffered_ranges.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const duration = Duration(seconds: 100);

  TorrentFileAvailability availability({
    bool isComplete = false,
    int fileSizeBytes = 1000,
    int readHeadBytes = 0,
    double bufferedSecondsAhead = 0,
    int bufferedPiecesAhead = 0,
  }) => TorrentFileAvailability(
    isComplete: isComplete,
    fileSizeBytes: fileSizeBytes,
    readHeadBytes: readHeadBytes,
    bufferedSecondsAhead: bufferedSecondsAhead,
    bufferedPiecesAhead: bufferedPiecesAhead,
  );

  group('torrentAvailabilityToBufferedRanges', () {
    test('verified-complete file covers the whole timeline', () {
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(isComplete: true, fileSizeBytes: 0),
        duration: duration,
      );
      expect(ranges, [
        const MediaForgeBufferedRange(
          start: Duration.zero,
          end: duration,
        ),
      ]);
    });

    test('stream window maps proportionally onto the timeline', () {
      // 1000-byte file, 100s media: read head at byte 250 → 25s,
      // 10 verified seconds ahead → [25s, 35s].
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(
          fileSizeBytes: 1000,
          readHeadBytes: 250,
          bufferedSecondsAhead: 10,
          bufferedPiecesAhead: 5,
        ),
        duration: duration,
      );
      expect(ranges, [
        const MediaForgeBufferedRange(
          start: Duration(seconds: 25),
          end: Duration(seconds: 35),
        ),
      ]);
    });

    test('window clamps to the media duration', () {
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(
          fileSizeBytes: 1000,
          readHeadBytes: 950,
          bufferedSecondsAhead: 30,
        ),
        duration: duration,
      );
      expect(ranges, [
        const MediaForgeBufferedRange(
          start: Duration(seconds: 95),
          end: duration,
        ),
      ]);
    });

    test('empty when duration, size, or window is unknown', () {
      expect(
        torrentAvailabilityToBufferedRanges(
          availability: availability(isComplete: true),
          duration: Duration.zero,
        ),
        isEmpty,
      );
      expect(
        torrentAvailabilityToBufferedRanges(
          availability: availability(fileSizeBytes: 0),
          duration: duration,
        ),
        isEmpty,
      );
      expect(
        torrentAvailabilityToBufferedRanges(
          availability: availability(
            fileSizeBytes: 1000,
            bufferedSecondsAhead: 0,
          ),
          duration: duration,
        ),
        isEmpty,
      );
      expect(
        torrentAvailabilityToBufferedRanges(
          availability: availability(
            fileSizeBytes: 1000,
            bufferedSecondsAhead: -5,
          ),
          duration: duration,
        ),
        isEmpty,
      );
      expect(
        torrentAvailabilityToBufferedRanges(
          availability: availability(
            fileSizeBytes: 1000,
            bufferedSecondsAhead: double.nan,
          ),
          duration: duration,
        ),
        isEmpty,
      );
    });

    test('overall progress alone never fabricates a range', () {
      // No verified window (seconds == 0) even with pieces reported:
      // sparse pieces must not appear as contiguous availability.
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(
          fileSizeBytes: 1000,
          readHeadBytes: 0,
          bufferedSecondsAhead: 0,
          bufferedPiecesAhead: 40,
        ),
        duration: duration,
      );
      expect(ranges, isEmpty);
    });

    test('results are normalized and sorted', () {
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(
          fileSizeBytes: 2000,
          readHeadBytes: 0,
          bufferedSecondsAhead: 5,
        ),
        duration: duration,
      );
      expect(ranges, hasLength(1));
      expect(ranges.single.start, Duration.zero);
      expect(ranges.single.end, const Duration(seconds: 5));
    });
  });

  group('StreamingService.currentTorrentAvailability', () {
    test('null with no session', () {
      final service = StreamingService(_AvailabilityEngine(null));
      expect(service.currentTorrentAvailability(), isNull);
    });

    test('forwards the engine snapshot for the active session', () async {
      const snapshot = TorrentFileAvailability(
        isComplete: false,
        fileSizeBytes: 2000,
        readHeadBytes: 500,
        bufferedSecondsAhead: 12,
        bufferedPiecesAhead: 6,
      );
      final service = StreamingService(_AvailabilityEngine(snapshot));
      await service.start(_magnetSource());
      final actual = service.currentTorrentAvailability();
      expect(actual, isNotNull);
      expect(actual!.fileSizeBytes, 2000);
      expect(actual.readHeadBytes, 500);
      expect(actual.bufferedSecondsAhead, 12);
      await service.dispose();
    });

    test('null when the engine has no availability capability', () async {
      final service = StreamingService(_PlainEngine());
      await service.start(_magnetSource());
      expect(service.currentTorrentAvailability(), isNull);
      await service.dispose();
    });
  });

  group('MediaForge external ranges integration', () {
    test('mapped ranges reach the controller untouched', () {
      final controller = MediaForgePlayerController();
      addTearDown(controller.dispose);
      final ranges = torrentAvailabilityToBufferedRanges(
        availability: availability(
          fileSizeBytes: 1000,
          readHeadBytes: 250,
          bufferedSecondsAhead: 10,
        ),
        duration: duration,
      );
      controller.setExternalBufferedRanges(ranges);
      // Stored verbatim (normalized): the PeerStream→MediaForge handoff.
      expect(controller.externalBufferedRanges, ranges);
      // With no open source (zero duration) MediaForge clamps display
      // ranges to empty — its own tested behavior, unchanged here.
      expect(controller.value.bufferedRanges, isEmpty);
      controller.clearExternalBufferedRanges();
      expect(controller.externalBufferedRanges, isEmpty);
    });
  });
}

TorrentSource _magnetSource() => TorrentSource(
  id: 'availability-test',
  content: const MediaRef(id: 1, type: MediaType.movie),
  name: 't',
  uri: Uri.parse('magnet:?xt=urn:btih:${'a' * 40}'),
  inputType: TorrentInputType.magnet,
  providerName: 'test',
  attribution: 'test',
  license: 'test',
  provenanceUrl: Uri.parse('about:blank'),
);

class _AvailabilityEngine extends _BaseFakeEngine
    implements TorrentAvailabilityProvider {
  _AvailabilityEngine(this.snapshot);
  final TorrentFileAvailability? snapshot;

  @override
  TorrentFileAvailability? fileAvailability(int torrentId, int fileIndex) =>
      snapshot;
}

class _PlainEngine extends _BaseFakeEngine {}

class _BaseFakeEngine implements TorrentEngine {
  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;
  @override
  Future<void> initialize() async {}
  @override
  Future<TorrentHandle> add(TorrentSource source) async =>
      const TorrentHandle('1');
  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async =>
      const [
        TorrentFileEntry(index: 0, name: 'm.mp4', size: 2000, isStreamable: true),
      ];
  @override
  Stream<TorrentStats> watch(TorrentHandle handle) => const Stream.empty();
  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async => TorrentPlaybackStream(
    id: '9',
    uri: Uri.parse('http://127.0.0.1:1/x'),
    file: file,
  );
  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {}
  @override
  Future<void> dispose() async {}
}
