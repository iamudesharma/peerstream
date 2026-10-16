import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/downloads/downloads_screen.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/providers/app_providers.dart';
import 'package:peerstream/services/experience/playback_experience.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/streaming/offline_download.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';
import 'package:peerstream/services/video/desktop_video.dart';

import 'empty_playback_cache.dart';

class Engine extends Fake implements TorrentEngine {
  @override
  Future<void> dispose() async {}
}

final source = TorrentSource(
  id: 'downloaded',
  content: const MediaRef(id: -123, type: MediaType.movie),
  name: 'Original fixture',
  uri: Uri.parse('http://example.invalid/video.mp4'),
  inputType: TorrentInputType.directUrl,
  providerName: 'Fixture',
  attribution: 'Original',
  license: 'CC0',
  provenanceUrl: Uri.parse('about:blank'),
);

class SavedCache extends EmptyPlaybackCache {
  final saved = PlaybackCacheEntry(
    cacheKey: 'fixture',
    source: source,
    file: const TorrentFileEntry(
      index: 0,
      name: 'video.mp4',
      size: 100,
      isStreamable: true,
    ),
    filePath: '/isolated-fixture/video.mp4',
    complete: true,
    pinned: true,
    byteSize: 100,
    lastUsedAt: DateTime(2026),
  );
  bool available = true;
  @override
  Future<List<PlaybackCacheEntry>> entries() async => [saved];
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async =>
      available ? saved : null;
}

void main() {
  testWidgets(
    'completed download offers play, external player and verified file export',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DesktopVideo.channel,
        (call) async {
          calls.add(call);
          return '/isolated-fixture/copy.mp4';
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DesktopVideo.channel,
          null,
        ),
      );
      final cache = SavedCache();
      final service = StreamingService.withExperience(
        Engine(),
        cache,
        PlaybackExperience(read: () async => {}, write: (_) async {}),
      );

      service.offline.state.value = OfflineJob(
        source,
        OfflinePhase.complete,
        bytes: 100,
        total: 100,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamingServiceProvider.overrideWithValue(service),
            playbackCacheProvider.overrideWithValue(cache),
          ],
          child: const MaterialApp(home: DownloadsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Original fixture'), findsOneWidget);
      await tester.tap(find.byTooltip('Offline save actions'));
      await tester.pumpAndSettle();
      expect(find.text('Play downloaded video'), findsOneWidget);
      expect(find.text('Open in external player…'), findsOneWidget);
      await tester.tap(find.text('Save file as…'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'export');
      expect(calls.single.arguments['path'], '/isolated-fixture/video.mp4');
      expect(find.text('Video file saved.'), findsOneWidget);
      // A stale/missing saved path must never reach the native export method.
      cache.available = false;
      await tester.tap(find.byTooltip('Offline save actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save file as…'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      await tester.pumpWidget(const SizedBox());
      await service.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
