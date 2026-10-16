import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/services/playback/playback_cache.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/playback/torrent_cache_identity.dart';
import 'package:peerstream/services/storage/app_storage_native.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';
import 'package:peerstream/services/torrent/bundled_torrent_api.dart';
import 'package:peerstream/services/torrent/native_torrent_engine.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native HTTP playback can restart after clearing external cache', (
    tester,
  ) async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      const MaterialApp(home: Text('Verifying storage reset…')),
    );
    await tester.runAsync(() async {
      await appStorage.initialize();
      final location = await appStorage.location();
      expect(
        location.custom,
        isTrue,
        reason: 'Select the SSD folder before this test.',
      );
      final fixture = await Directory(await appStorage.temporaryDirectoryPath())
          .createTemp('storage-reset-test-');
      final storage = _FixtureStorage(fixture);
      final cache = _FixtureCache(fixture);
      final engine = NativeTorrentEngine(
        cache: cache,
        sessionCacheDirectory: storage.cacheDirectoryPath,
      );
      final service = StreamingService(engine, cache);
      final source = (await const BundledLegalTorrentApi().findByContent(
        const MediaRef(id: 10378, type: MediaType.movie),
      )).single;
      try {
        for (var pass = 0; pass < 2; pass++) {
          await service.start(source).timeout(const Duration(seconds: 60));
          final uri = service.state.playback!.uri;
          expect(uri.host, '127.0.0.1');
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 10);
          try {
            final request = await client.getUrl(uri);
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
            final response = await request.close().timeout(
              const Duration(seconds: 60),
            );
            expect(response.statusCode, HttpStatus.partialContent);
            final bytes = await response.fold<int>(
              0,
              (count, chunk) => count + chunk.length,
            );
            expect(bytes, 1024);
          } finally {
            client.close(force: true);
          }
          final identity = await engine.engineDiagnostics();
          expect(identity.bridgeVersion, nativeBridgeVersion);
          debugPrint(
            '[StorageVerification] pass=${pass + 1} native=${identity.bridgeVersion} range=206 bytes=1024 root=${fixture.path}',
          );
          await service.clearCache(() async {
            await cache.clear();
            final session = Directory(await storage.cacheDirectoryPath());
            if (await session.exists()) await session.delete(recursive: true);
          });
          expect(await Directory('${fixture.path}/payload').exists(), isFalse);
        }
      } finally {
        await service.dispose();
        await fixture.delete(recursive: true);
      }
    });
  });
}

class _FixtureStorage extends AppStorage {
  _FixtureStorage(this.root);
  final Directory root;
  @override
  Future<String> dataDirectoryPath() async =>
      (await Directory('${root.path}/data').create(recursive: true)).path;
  @override
  Future<String> cacheDirectoryPath() async =>
      (await Directory('${root.path}/cache').create(recursive: true)).path;
}

class _FixtureCache extends PlaybackCacheStore {
  _FixtureCache(this.root);
  final Directory root;
  @override
  Future<String> directoryPathFor(TorrentSource source) async =>
      (await Directory('${root.path}/payload/${torrentCacheKey(source)}')
              .create(recursive: true))
          .path;
  @override
  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async => null;
  @override
  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) async {}
  @override
  Future<void> clear() async {
    final payload = Directory('${root.path}/payload');
    if (await payload.exists()) await payload.delete(recursive: true);
  }
}
