import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/player/external_player_screen.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/providers/app_providers.dart';
import 'package:peerstream/services/experience/playback_experience.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/source_policy.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';
import 'package:peerstream/services/video/desktop_video.dart';

import 'empty_playback_cache.dart';

class Engine extends Fake implements TorrentEngine {
  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets(
    'blocked saved source is rejected before preparing or opening another app',
    (tester) async {
      final service = StreamingService.withExperience(
        Engine(),
        EmptyPlaybackCache(),
        PlaybackExperience(read: () async => {}, write: (_) async {}),
      );
      final source = TorrentSource(
        id: 'blocked-fixture',
        content: const MediaRef(id: -456, type: MediaType.movie),
        name: 'Blocked fixture',
        uri: Uri.parse('https://example.invalid/video.mp4'),
        inputType: TorrentInputType.directUrl,
        providerName: 'Fixture',
        attribution: 'Original',
        license: 'CC0',
        provenanceUrl: Uri.parse('about:blank'),
      );
      final container = ProviderContainer(
        overrides: [
          streamingServiceProvider.overrideWithValue(service),
          sourcePolicyProvider.overrideWith(
            (ref) async =>
                const SourcePolicy(blockedSourceIds: {'blocked-fixture'}),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ExternalPlayerScreen(
              request: ExternalPlayerRequest(
                source,
                const ExternalVideoPlayer('fixture', 'Fixture'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This source is blocked by your source settings.'),
        findsOneWidget,
      );
      expect(service.state.phase, StreamingPhase.idle);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump();
      await service.dispose();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
