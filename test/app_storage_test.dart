import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:peerstream/services/playback/playback_cache_native.dart';
import 'package:peerstream/services/playback/playback_cache_models.dart';
import 'package:peerstream/services/storage/app_storage_native.dart';
import 'package:peerstream/services/storage/storage_location.dart';
import 'package:peerstream/core/image_cache_native.dart';
import 'package:peerstream/services/history/watch_history_store_native.dart'
    as history_store;
import 'package:peerstream/services/mylist/my_list_store_native.dart'
    as list_store;

class _Locator extends StorageLocator {
  StorageFolder? current;
  StorageFolder? pending;
  bool failCommit = false;
  bool failRead = false;
  int reads = 0;
  @override
  Future<(StorageFolder?, StorageFolder?)> read() async {
    reads++;
    if (failRead) throw StateError('Storage locator unavailable');
    return (current, pending);
  }

  @override
  Future<StorageFolder> restoreAccess(StorageFolder folder) async => folder;
  @override
  Future<void> write(StorageFolder? active, StorageFolder? next) async {
    if (failCommit && active != null) throw StateError('Locator write failed');
    current = active;
    pending = next;
  }
}

void main() {
  late Directory sandbox;
  late Directory data;
  late Directory cache;
  late Directory destination;
  late _Locator locator;

  AppStorage storage() => AppStorage(
    locator: locator,
    defaultDataPath: () async => data.path,
    defaultCachePath: () async => cache.path,
    defaultTemporaryPath: () async => p.join(sandbox.path, 'original-temp'),
  );

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('peerstream-storage-test-');
    data = await Directory(p.join(sandbox.path, 'original-data')).create();
    cache = await Directory(p.join(sandbox.path, 'original-cache')).create();
    destination = await Directory(p.join(sandbox.path, 'ssd')).create();
    locator = _Locator();
  });
  tearDown(() async => sandbox.delete(recursive: true));

  test('locator failures block fallback writes and can be retried', () async {
    var fallbackCalls = 0;
    locator.failRead = true;
    final app = AppStorage(
      locator: locator,
      defaultDataPath: () async {
        fallbackCalls++;
        return data.path;
      },
      defaultCachePath: () async => cache.path,
      defaultTemporaryPath: () async => sandbox.path,
    );
    await expectLater(app.dataDirectoryPath(), throwsStateError);
    expect(fallbackCalls, 0);
    locator.failRead = false;
    locator.current = StorageFolder(destination.path);
    await app.initialize();
    expect(locator.reads, 2);
    expect((await app.location()).path, destination.path);
    expect(fallbackCalls, 0);
  });

  test(
    'invalid or unavailable saved lists are never treated as empty',
    () async {
      final app = storage();
      final history = File(p.join(data.path, 'peerstream-watch-history.json'));
      final saved = File(p.join(data.path, 'peerstream-my-list.json'));
      await history.writeAsString('{"invalid":"list"}');
      await saved.writeAsString('broken JSON');
      await expectLater(
        history_store.readWatchHistory(storage: app),
        throwsFormatException,
      );
      await expectLater(
        list_store.readMyList(storage: app),
        throwsFormatException,
      );
      locator.current = StorageFolder(destination.path);
      await destination.delete();
      final disconnected = storage();
      await expectLater(
        history_store.writeWatchHistory([], storage: disconnected),
        throwsA(isA<StorageUnavailableException>()),
      );
      await expectLater(
        list_store.writeMyList([], storage: disconnected),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await history.readAsString(), '{"invalid":"list"}');
      expect(await saved.readAsString(), 'broken JSON');
    },
  );

  test(
    'full disposable volume preserves cache metadata and recovers',
    () async {
      final mount = Directory(Platform.environment['PEERSTREAM_FAULT_VOLUME']!);
      expect(
        await File(p.join(mount.path, '.peerstream-fault-test-volume'))
            .readAsString(),
        'PeerStream disposable 64 MiB verification volume',
      );
      expect(p.basename(mount.path), 'mount');
      expect(
        p.basename(mount.parent.path),
        startsWith('peerstream-fault-volume-'),
      );
      final disk = await Process.run('/bin/df', ['-k', mount.path]);
      final fields = (disk.stdout as String)
          .trim()
          .split('\n')
          .last
          .split(RegExp(r'\s+'));
      expect(
        int.parse(fields[1]),
        lessThanOrEqualTo(128 * 1024),
        reason: 'Only fill the disposable small test filesystem.',
      );
      final root = await mount.createTemp('app-storage-');
      final app = AppStorage(
        locator: _Locator()..current = StorageFolder(root.path),
      );
      final store = PlaybackCacheStore(storage: app);
      final filler = File(p.join(mount.path, 'verification-filler'));
      try {
        await store.savePreferences(
          const PlaybackPreferences(maxCacheBytes: 1024),
        );
        final index = File(
          p.join(root.path, 'data', 'peerstream-playback-cache.json'),
        );
        final original = await index.readAsBytes();
        final handle = await filler.open(mode: FileMode.write);
        var full = false;
        try {
          for (final size in [1024 * 1024, 4096]) {
            final block = List<int>.filled(size, 120);
            try {
              for (var i = 0; i < (size == 4096 ? 4096 : 128); i++) {
                await handle.writeFrom(block);
              }
            } on FileSystemException catch (error) {
              expect(error.osError?.errorCode, 28);
              full = true;
            }
          }
        } finally {
          await handle.close();
        }
        expect(full, isTrue);
        expect(
          (await app.checkHealth(checkWritable: true)).status,
          StorageHealthStatus.full,
        );
        await expectLater(
          store.savePreferences(const PlaybackPreferences(maxCacheBytes: 2048)),
          throwsA(isA<FileSystemException>()),
        );
        expect(await index.readAsBytes(), original);
        await filler.delete();
        expect(
          (await app.checkHealth(checkWritable: true)).status,
          StorageHealthStatus.ready,
        );
        expect((await store.preferences()).maxCacheBytes, 1024);
        await store.savePreferences(
          const PlaybackPreferences(maxCacheBytes: 2048),
        );
        expect((await store.preferences()).maxCacheBytes, 2048);
      } finally {
        if (await filler.exists()) await filler.delete();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['PEERSTREAM_FAULT_VOLUME'] == null,
  );

  test(
    'interrupted install is rolled back and copied again before activation',
    () async {
      final original = File(p.join(data.path, 'peerstream-watch-history.json'));
      await original.writeAsString('[{"key":"preserved"}]');
      await storage().scheduleMove(StorageFolder(destination.path));
      const nonce = '0123456789abcdef0123456789abcdef';
      final staging = await Directory(
        p.join(destination.path, '.peerstream-move-interrupted'),
      ).create();
      final partial = await Directory(p.join(destination.path, 'data'))
          .create();
      await File(p.join(partial.path, '.peerstream-move-owner'))
          .writeAsString(nonce);
      await File(p.join(partial.path, 'peerstream-watch-history.json'))
          .writeAsString('partial copy');
      await File(p.join(staging.path, 'partial')).writeAsString('unfinished');
      await File(p.join(destination.path, '.peerstream-move.json'))
          .writeAsString(
            jsonEncode({
              'version': 1,
              'nonce': nonce,
              'destination': destination.path,
              'sourceData': data.path,
              'staging': p.basename(staging.path),
            }),
          );
      final restarted = storage();
      await restarted.initialize();
      expect((await restarted.location()).problem, isNull);
      expect(locator.current?.path, destination.path);
      expect(
        await File(
          p.join(destination.path, 'data', 'peerstream-watch-history.json'),
        ).readAsString(),
        '[{"key":"preserved"}]',
      );
      expect(await staging.exists(), isFalse);
      expect(
        await File(p.join(destination.path, '.peerstream-move.json')).exists(),
        isFalse,
      );
      expect(
        await File(p.join(destination.path, 'data', '.peerstream-move-owner'))
            .exists(),
        isFalse,
      );
    },
  );

  test('interrupted move refuses unowned destination contents without deleting them', () async {
    await File(p.join(data.path, 'peerstream-settings.json'))
        .writeAsString('original');
    await storage().scheduleMove(StorageFolder(destination.path));
    final partial = await Directory(p.join(destination.path, 'data')).create();
    final unrelated = File(p.join(partial.path, 'keep.txt'));
    await unrelated.writeAsString('unrelated');
    await File(p.join(destination.path, '.peerstream-move.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'nonce': '0123456789abcdef0123456789abcdef',
        'destination': destination.path,
        'sourceData': data.path,
        'staging': '.peerstream-move-interrupted',
      }),
    );
    final restarted = storage();
    await restarted.initialize();
    expect((await restarted.location()).problem, contains('unrecognized'));
    expect(await unrelated.readAsString(), 'unrelated');
    expect(
      await File(p.join(data.path, 'peerstream-settings.json')).readAsString(),
      'original',
    );
    expect(locator.current, isNull);
  });

  test(
    'a migration marker never authorizes deletion of unrelated new files',
    () async {
      await File(p.join(data.path, 'peerstream-settings.json'))
          .writeAsString('original');
      await storage().scheduleMove(StorageFolder(destination.path));
      const nonce = '0123456789abcdef0123456789abcdef';
      final partial = await Directory(p.join(destination.path, 'data'))
          .create();
      await File(p.join(partial.path, '.peerstream-move-owner'))
          .writeAsString(nonce);
      final unrelated = File(p.join(partial.path, 'new-user-file.txt'));
      await unrelated.writeAsString('retain this file');
      await File(p.join(destination.path, '.peerstream-move.json'))
          .writeAsString(
            jsonEncode({
              'version': 1,
              'nonce': nonce,
              'destination': destination.path,
              'sourceData': data.path,
              'staging': '.peerstream-move-interrupted',
            }),
          );
      final restarted = storage();
      await restarted.initialize();
      expect((await restarted.location()).problem, contains('unrecognized'));
      expect(await unrelated.readAsString(), 'retain this file');
      expect(
        await File(p.join(data.path, 'peerstream-settings.json'))
            .readAsString(),
        'original',
      );
      expect(locator.current, isNull);
    },
  );

  test(
    'storage disappearance and reconnection never create an internal fallback',
    () async {
      locator.current = StorageFolder(destination.path);
      final app = storage();
      await app.initialize();
      final absent = await destination.rename(
        p.join(sandbox.path, 'disconnected'),
      );
      expect(
        (await app.checkHealth(checkWritable: true)).status,
        StorageHealthStatus.disconnected,
      );
      await expectLater(
        app.dataDirectoryPath(),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await data.list().isEmpty, isTrue);
      expect(await Directory(destination.path).exists(), isFalse);
      await absent.rename(destination.path);
      expect(
        (await app.checkHealth(checkWritable: true)).status,
        StorageHealthStatus.ready,
      );
      expect(await app.dataDirectoryPath(), p.join(destination.path, 'data'));
    },
  );

  test('unwritable selected folder is reported distinctly', () async {
    locator.current = StorageFolder(destination.path);
    final app = storage();
    await app.initialize();
    await Process.run('/bin/chmod', ['500', destination.path]);
    try {
      expect(
        (await app.checkHealth(checkWritable: true)).status,
        StorageHealthStatus.unwritable,
      );
    } finally {
      await Process.run('/bin/chmod', ['700', destination.path]);
    }
  }, skip: Platform.isWindows);

  test(
    'reselecting the active folder cancels a different pending move',
    () async {
      locator.current = StorageFolder(destination.path);
      final app = storage();
      final another = await Directory(p.join(sandbox.path, 'another-ssd'))
          .create();
      await app.scheduleMove(StorageFolder(another.path));
      expect((await app.location()).pendingPath, another.path);
      await app.scheduleMove(StorageFolder(destination.path));
      expect((await app.location()).pendingPath, isNull);
      expect(locator.pending, isNull);
      expect((await app.location()).path, destination.path);
    },
  );

  test(
    'move waits for restart, preserves user data and rebases cached files',
    () async {
      final video = File(
        p.join(data.path, 'peerstream-playback-v1', 'abc', 'clip.mkv'),
      );
      await video.parent.create(recursive: true);
      await video.writeAsString('verified pieces');
      await File(p.join(video.parent.path, 'resume.dat'))
          .writeAsString('resume state');
      final history = File(p.join(data.path, 'peerstream-watch-history.json'));
      await history.writeAsString('[{"id":42}]');
      await File(p.join(data.path, 'peerstream-playback-cache.json'))
          .writeAsString(
            jsonEncode({
              'entries': [
                {'filePath': video.path},
              ],
            }),
          );
      final unrelated = File(p.join(data.path, 'unrelated.txt'));
      await unrelated.writeAsString('keep');
      final app = storage();
      await app.scheduleMove(StorageFolder(destination.path));
      expect(await app.dataDirectoryPath(), data.path);
      expect(await video.exists(), isTrue);
      expect((await app.location()).pendingPath, destination.path);

      final restarted = storage();
      await restarted.initialize();
      final newData = await restarted.dataDirectoryPath();
      expect(newData, p.join(destination.path, 'data'));
      expect(
        await File(p.join(newData, 'peerstream-watch-history.json'))
            .readAsString(),
        '[{"id":42}]',
      );
      expect(
        await File(p.join(newData, 'peerstream-playback-v1', 'abc', 'clip.mkv'))
            .readAsString(),
        'verified pieces',
      );
      expect(
        await File(
          p.join(newData, 'peerstream-playback-v1', 'abc', 'resume.dat'),
        ).readAsString(),
        'resume state',
      );
      final index = jsonDecode(
        await File(p.join(newData, 'peerstream-playback-cache.json'))
            .readAsString(),
      ) as Map;
      expect(
        (index['entries'] as List).single['filePath'],
        p.join(newData, 'peerstream-playback-v1', 'abc', 'clip.mkv'),
      );
      expect(await video.exists(), isFalse);
      expect(await history.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
      expect(locator.current?.path, destination.path);
      expect(locator.pending, isNull);
    },
  );

  test(
    'unavailable external drive does not fall back or recreate storage',
    () async {
      locator.current = StorageFolder(destination.path);
      await destination.delete();
      final app = storage();
      await app.initialize();
      expect((await app.location()).path, destination.path);
      expect((await app.location()).problem, contains('unavailable'));
      await expectLater(
        app.dataDirectoryPath(),
        throwsA(isA<StorageUnavailableException>()),
      );
      await expectLater(
        app.cacheDirectoryPath(),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await destination.exists(), isFalse);
      expect(await data.list().isEmpty, isTrue);
    },
  );

  test(
    'cannot move from a disconnected drive into an empty replacement',
    () async {
      locator.current = StorageFolder(p.join(sandbox.path, 'disconnected-ssd'));
      locator.pending = StorageFolder(destination.path);
      final app = storage();
      await app.initialize();
      expect((await app.location()).problem, contains('unavailable'));
      expect(locator.current!.path, contains('disconnected-ssd'));
      expect(await destination.list().isEmpty, isTrue);
    },
  );

  test(
    'artwork files and index use selected storage, support resizing and clear',
    () async {
      await storage().scheduleMove(StorageFolder(destination.path));
      final relocated = storage();
      await relocated.initialize();
      final manager = ArtworkCacheManager(storage: relocated);
      expect(manager, isA<ImageCacheManager>());
      final pixel = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCqkAAAAASUVORK5CYII=',
      );
      final file = await manager.putFile(
        'https://example.test/artwork.png',
        pixel,
        fileExtension: 'png',
      );
      expect(p.isWithin(p.join(destination.path, 'cache'), file.path), isTrue);
      expect(await file.readAsBytes(), pixel);
      await manager.dispose();
      expect(
        await File(p.join(destination.path, 'cache', 'artwork', 'index.json'))
            .exists(),
        isTrue,
      );
      final reopened = ArtworkCacheManager(storage: relocated);
      expect(
        (await reopened.getFileFromCache('https://example.test/artwork.png'))
            ?.file
            .path,
        file.path,
      );
      await reopened.emptyCache();
      expect(await file.exists(), isFalse);
      await reopened.dispose();
      expect(await cache.list().isEmpty, isTrue);
    },
  );

  test(
    'copy failure keeps original data and removes only staging files',
    () async {
      final history = File(p.join(data.path, 'peerstream-watch-history.json'));
      await history.writeAsString('history');
      await Link(p.join(data.path, 'subtitles')).create(data.path);
      await storage().scheduleMove(StorageFolder(destination.path));
      final restarted = storage();
      await restarted.initialize();
      expect((await restarted.location()).problem, contains('symbolic link'));
      expect(await restarted.dataDirectoryPath(), data.path);
      expect(await history.readAsString(), 'history');
      expect(await destination.list().isEmpty, isTrue);
      expect(locator.current, isNull);
    },
  );

  test(
    'locator commit failure rolls back destination and retains source',
    () async {
      final history = File(p.join(data.path, 'peerstream-watch-history.json'));
      await history.writeAsString('history');
      await storage().scheduleMove(StorageFolder(destination.path));
      locator.failCommit = true;
      final restarted = storage();
      await restarted.initialize();
      expect(
        (await restarted.location()).problem,
        contains('Locator write failed'),
      );
      expect(await history.readAsString(), 'history');
      expect(await destination.list().isEmpty, isTrue);
      expect(locator.current, isNull);
      expect(locator.pending?.path, destination.path);
    },
  );

  test(
    'rejects existing data and overlapping destination without touching it',
    () async {
      final existing = await Directory(p.join(destination.path, 'data'))
          .create();
      final other = File(p.join(existing.path, 'keep.txt'));
      await other.writeAsString('keep');
      final app = storage();
      await expectLater(
        app.scheduleMove(StorageFolder(destination.path)),
        throwsA(isA<StorageUnavailableException>()),
      );
      await expectLater(
        app.scheduleMove(StorageFolder(data.path)),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await other.readAsString(), 'keep');
      expect(locator.pending, isNull);
    },
  );

  test(
    'clearing video cache preserves cache limit and language preferences',
    () async {
      final app = storage();
      final store = PlaybackCacheStore(storage: app);
      const preferences = PlaybackPreferences(
        maxCacheBytes: 1024,
        preferredAudioLanguage: 'hin',
        preferredSubtitleLanguage: 'eng',
      );
      await store.savePreferences(preferences);
      final payload = File(
        p.join(data.path, 'peerstream-playback-v1', 'abc', 'clip.mkv'),
      );
      await payload.parent.create(recursive: true);
      await payload.writeAsString('cached video');
      await store.clear();
      expect(await payload.exists(), isFalse);
      final retained = await store.preferences();
      expect(retained.maxCacheBytes, 1024);
      expect(retained.preferredAudioLanguage, 'hin');
      expect(retained.preferredSubtitleLanguage, 'eng');
      expect((await store.summary()).byteSize, 0);
    },
  );
}
