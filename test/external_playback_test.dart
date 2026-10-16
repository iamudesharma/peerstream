import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/experience/playback_experience.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';
import 'package:peerstream/services/video/desktop_video.dart';
import 'package:peerstream/services/video/external_playback.dart';

import 'empty_playback_cache.dart';

final source = TorrentSource(
  id: 'external-fixture',
  content: const MediaRef(id: -900, type: MediaType.movie),
  name: 'Fixture',
  uri: Uri.parse('https://example.invalid/video.mkv'),
  inputType: TorrentInputType.directUrl,
  providerName: 'Original',
  attribution: 'Original',
  license: 'CC0',
  provenanceUrl: Uri.parse('about:blank'),
);

class Engine extends Fake implements TorrentEngine {
  @override
  bool get isSupported => true;
  @override
  String get unsupportedReason => '';
  @override
  Future<void> dispose() async {}
}

class Desktop extends DesktopVideo {
  final opened = <Uri>[];
  bool fail = false;
  @override
  Future<void> open(Uri uri, ExternalVideoPlayer player) async {
    if (fail) throw StateError('Player unavailable');
    opened.add(uri);
  }
}

StreamingService service([EmptyPlaybackCache? cache]) =>
    StreamingService.withExperience(
      Engine(),
      cache ?? EmptyPlaybackCache(),
      PlaybackExperience(read: () async => {}, write: (_) async {}),
    );
void main() {
  test('handoff retains session without claiming a decoded frame', () async {
    final streaming = service();
    final desktop = Desktop();
    final session = ExternalPlayback(streaming, desktop);
    await session.start(
      source,
      const ExternalVideoPlayer('fixture.player', 'Fixture player'),
    );
    expect(desktop.opened, [source.uri]);
    expect(streaming.state.phase, StreamingPhase.ready);
    expect(streaming.state.diagnostics?['firstFrameAt'], isNull);
    await session.close();
    expect(streaming.state.phase, StreamingPhase.stopped);
    await streaming.dispose();
  });
  test('launch failure releases the owned stream', () async {
    final streaming = service();
    final desktop = Desktop()..fail = true;
    await expectLater(
      ExternalPlayback(
        streaming,
        desktop,
      ).start(source, const ExternalVideoPlayer('missing', 'Missing')),
      throwsStateError,
    );
    expect(streaming.state.phase, StreamingPhase.stopped);
    await streaming.dispose();
  });
  test(
    'closing a stale handoff does not stop a newer playback session',
    () async {
      final streaming = service();
      final desktop = Desktop();
      final session = ExternalPlayback(streaming, desktop);
      await session.start(
        source,
        const ExternalVideoPlayer('fixture', 'Fixture'),
      );
      await streaming.start(source);
      final newer = streaming.state.sessionId;
      await session.close();
      expect(streaming.state.sessionId, newer);
      expect(streaming.state.phase, StreamingPhase.ready);
      await streaming.dispose();
    },
  );
  test(
    'cancel during preparation never launches another application',
    () async {
      final cache = WaitingCache();
      final streaming = service(cache);
      final desktop = Desktop();
      final session = ExternalPlayback(streaming, desktop);
      final starting = session.start(
        source,
        const ExternalVideoPlayer('fixture', 'Fixture'),
      );
      await cache.requested.future;
      await session.close();
      cache.complete.complete(null);
      await starting;
      expect(desktop.opened, isEmpty);
      expect(streaming.state.phase, StreamingPhase.stopped);
      await streaming.dispose();
    },
  );
}

class WaitingCache extends EmptyPlaybackCache {
  final requested = Completer<void>();
  final complete = Completer<PlaybackCacheEntry?>();
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) {
    requested.complete();
    return complete.future;
  }
}
