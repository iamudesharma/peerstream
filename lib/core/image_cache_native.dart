import 'dart:io' as io;

import 'package:file/file.dart' show File;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../services/storage/app_storage_native.dart';

CacheManager? _manager;
BaseCacheManager get artworkCacheManager => _manager ??= ArtworkCacheManager();

/// Keep image resizing supported when replacing the package's default cache.
class ArtworkCacheManager extends CacheManager with ImageCacheManager {
  ArtworkCacheManager({AppStorage? storage})
    : super(
        Config(
          'peerstream-artwork-v1',
          maxNrOfCacheObjects: 300,
          fileSystem: _ArtworkFileSystem(storage ?? appStorage),
          repo: _ArtworkRepository(storage ?? appStorage),
        ),
      );
}

Future<void> clearArtworkCache() async {
  final manager = _manager;
  if (manager != null) await manager.emptyCache();
}

class _ArtworkFileSystem implements FileSystem {
  _ArtworkFileSystem(this.storage);
  final AppStorage storage;
  @override
  Future<File> createFile(String name) async {
    final directory = io.Directory(
      p.join(await storage.cacheDirectoryPath(), 'artwork', 'files'),
    );
    await directory.create(recursive: true);
    return const LocalFileSystem().file(p.join(directory.path, name));
  }
}

class _ArtworkRepository extends JsonCacheInfoRepository {
  _ArtworkRepository(this.storage)
    : super(databaseName: 'peerstream-artwork-v1');
  final AppStorage storage;

  @override
  Future<bool> open() async {
    path = p.join(await storage.cacheDirectoryPath(), 'artwork', 'index.json');
    await io.Directory(p.dirname(path!)).create(recursive: true);
    return super.open();
  }
}
