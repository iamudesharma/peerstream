import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/torrent_models.dart';
import '../../models/media_item.dart';
import '../../models/watch_progress.dart';
import 'playback_cache_models.dart';
import 'torrent_cache_identity.dart';

class PlaybackCacheStore {
  Future<void> _serial = Future.value();

  static const _directoryName = 'peerstream-playback-v1';
  static const _indexName = 'peerstream-playback-cache.json';

  static int get defaultMaxBytes =>
      Platform.isAndroid ? 1024 * 1024 * 1024 : 5 * 1024 * 1024 * 1024;

  Future<Directory> directoryFor(TorrentSource source) async {
    final root = await _root();
    return Directory(
      '${root.path}${Platform.pathSeparator}${torrentCacheKey(source)}',
    )..createSync(recursive: true);
  }

  Future<String> directoryPathFor(TorrentSource source) async =>
      (await directoryFor(source)).path;

  Future<PlaybackCacheEntry?> lookup(TorrentSource source) async {
    final state = await _read();
    return state.entries[torrentCacheKey(source)];
  }

  Future<PlaybackCacheEntry?> lookupWatch(WatchEntry entry) async {
    final state = await _read();
    for (final value in state.entries.values) {
      if (value.matchesWatchEntry(entry)) return value;
    }
    return null;
  }

  Future<PlaybackCacheEntry?> lookupRequest(
    MediaRef media,
    int? season,
    int? episode,
    String sourceId,
  ) async {
    final state = await _read();
    for (final value in state.entries.values) {
      if (value.source.id == sourceId &&
          value.source.content == media &&
          value.source.seasonNumber == season &&
          value.source.episodeNumber == episode) {
        return value;
      }
    }
    return null;
  }

  Future<bool> hasCompleteFile(TorrentSource source) async {
    final entry = await lookup(source);
    if (entry == null) {
      debugPrint('[Cache] no entry for ${torrentCacheKey(source)}');
      return false;
    }
    if (!entry.complete) {
      debugPrint('[Cache] ${entry.cacheKey} is not complete yet');
      return false;
    }
    if (entry.filePath.isEmpty) {
      debugPrint('[Cache] ${entry.cacheKey} has no file path');
      return false;
    }
    // Sparse-file guard: preallocated files report full length while missing
    // verified pieces. Require recorded bytes to agree with the file size.
    if (entry.file.size <= 0 || entry.byteSize < entry.file.size) {
      debugPrint(
        '[Cache] ${entry.cacheKey} size mismatch: '
        'byteSize=${entry.byteSize} fileSize=${entry.file.size}',
      );
      return false;
    }
    try {
      final resolvedPath = await _resolveFilePath(
        entry.filePath,
        fileName: entry.file.name,
      );
      final file = File(resolvedPath);
      final exists = await file.exists();
      final length = exists ? await file.length() : 0;
      final ok = exists && length >= entry.file.size;
      if (!ok) {
        debugPrint(
          '[Cache] ${entry.cacheKey} file check failed: '
          'exists=$exists length=$length expected=${entry.file.size} '
          'path=$resolvedPath',
        );
      }
      return ok;
    } on FileSystemException catch (error) {
      debugPrint('[Cache] ${entry.cacheKey} file check error: $error');
      return false;
    }
  }

  Future<List<PlaybackCacheEntry>> entries() async {
    final entries = (await _read()).entries.values.toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return entries;
  }

  Future<PlaybackCacheEntry?> completeFile(TorrentSource source) async {
    final entry = await lookup(source);
    if (entry == null || !await hasCompleteFile(source)) return null;
    // Heal stale absolute paths after the cache root moved or when the
    // torrent's files are nested under its root directory.
    final resolved = await _resolveFilePath(
      entry.filePath,
      fileName: entry.file.name,
    );
    return resolved == entry.filePath
        ? entry
        : entry.copyWith(filePath: resolved);
  }

  /// Records one observed (position → byte) seek anchor for [source]'s entry.
  ///
  /// Used to replace average-bitrate estimates with the file's real layout.
  /// Best effort: silently ignored when the entry or inputs are unusable.
  Future<void> recordTimeByteObservation(
    TorrentSource source,
    int positionMs,
    int byteOffset, {
    required int fileSize,
  }) => _locked(() async {
    if (positionMs <= 0 || byteOffset <= 0 || fileSize <= 0) return;
    final state = await _read();
    final key = torrentCacheKey(source);
    final entry = state.entries[key];
    if (entry == null) return;
    final merged = mergeTimeBytePoint(
      entry.timeBytePoints,
      TimeBytePoint(positionMs: positionMs, byteOffset: byteOffset),
      fileSize: fileSize,
    );
    state.entries[key] = entry.copyWith(timeBytePoints: merged);
    await _write(state);
    debugPrint(
      '[Cache] time->byte anchor key=$key '
      'pos=${positionMs}ms byte=$byteOffset anchors=${merged.length}',
    );
  });

  Future<void> record(
    TorrentSource source,
    TorrentFileEntry file, {
    required bool complete,
    required int byteSize,
    bool preserveComplete = false,
  }) => _locked(() async {
    final state = await _read();
    final directory = await directoryFor(source);
    // Multi-file torrents nest the file under the torrent's root directory;
    // record the real location when it already exists on disk.
    final direct = '${directory.path}${Platform.pathSeparator}${file.name}';
    final path = await _resolveFilePath(direct, fileName: file.name);
    final key = torrentCacheKey(source);
    final old = state.entries[key];
    // Completion and learned anchors are per *file*, but entries are keyed
    // per torrent. A season pack can have one episode complete while another
    // is requested — never leak flags across files.
    final sameFile =
        old != null &&
        old.file.index == file.index &&
        old.file.size == file.size &&
        old.file.name == file.name;
    state.entries[key] = PlaybackCacheEntry(
      cacheKey: key,
      source: source,
      file: file,
      filePath: path,
      // Verified completion overwrites; early registration preserves a
      // previously verified flag instead of clearing it.
      complete: preserveComplete
          ? (complete || (sameFile && old.complete))
          : complete,
      byteSize: byteSize > 0 ? byteSize : (sameFile ? old.byteSize : 0),
      lastUsedAt: DateTime.now(),
      // Learned time→byte anchors belong to the stored file.
      timeBytePoints: sameFile ? old.timeBytePoints : const [],
    );
    await _prune(state, protectedKey: key);
    await _write(state);
  });

  Future<PlaybackCacheSummary> summary() async {
    final state = await _read();
    return PlaybackCacheSummary(
      byteSize: await _rootSize(),
      maxBytes: state.preferences.maxCacheBytes,
      entries: state.entries.length,
    );
  }

  Future<PlaybackPreferences> preferences() async =>
      (await _read()).preferences;

  Future<void> savePreferences(PlaybackPreferences value) => _locked(() async {
    // Preference-only write: no cache pruning or directory-size scan here.
    // Audio/subtitle changes during playback must not trigger storage I/O.
    // Eviction runs explicitly via pruneIfNeeded() (storage settings) and
    // record() (new bytes arriving), never on a prefs save.
    final state = await _read();
    state.preferences = value;
    await _write(state);
  });

  /// Explicit eviction entry point for the storage settings screen.
  /// Never called from audio/subtitle preference saves or per-tick playback.
  Future<void> pruneIfNeeded({String? protectedKey}) => _locked(() async {
    final state = await _read();
    await _prune(state, protectedKey: protectedKey);
    await _write(state);
  });

  Future<void> remove(String cacheKey) => _locked(() async {
    final state = await _read();
    if (state.entries.remove(cacheKey) == null) return;
    final root = await _root();
    final target = Directory('${root.path}${Platform.pathSeparator}$cacheKey');
    if (await target.exists()) await target.delete(recursive: true);
    await _write(state);
  });

  Future<void> clear() => _locked(() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
    await _write(_CacheState.empty());
  });

  Future<void> _prune(_CacheState state, {String? protectedKey}) async {
    var used = await _rootSize();
    final ordered = state.entries.values.toList()
      ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    for (final entry in ordered) {
      if (used <= state.preferences.maxCacheBytes) break;
      if (entry.cacheKey == protectedKey) continue;
      final root = await _root();
      final target = Directory(
        '${root.path}${Platform.pathSeparator}${entry.cacheKey}',
      );
      final size = await _directorySize(target);
      if (await target.exists()) await target.delete(recursive: true);
      state.entries.remove(entry.cacheKey);
      used -= size;
    }
  }

  Future<_CacheState> _read() async {
    try {
      final file = await _indexFile();
      if (!await file.exists()) return _CacheState.empty();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return _CacheState.empty();
      return _CacheState.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return _CacheState.empty();
    }
  }

  Future<void> _write(_CacheState state) async {
    final file = await _indexFile();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    await temporary.rename(file.path);
  }

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final target = Directory(
      '${support.path}${Platform.pathSeparator}$_directoryName',
    );
    if (!await target.exists()) {
      await support.create(recursive: true);
      // Media used to live in the purgeable Caches directory, where macOS
      // deletes files under disk pressure (verified episodes vanished and
      // had to re-download). Move the tree once so downloaded data and
      // libtorrent fastresume state survive.
      final legacyPath = await _legacyRootPath();
      if (legacyPath != null) {
        final legacy = Directory(legacyPath);
        try {
          if (await legacy.exists()) await legacy.rename(target.path);
        } catch (_) {}
      }
    }
    return target..createSync(recursive: true);
  }

  /// Old cache location: `.../Library/Caches/<app>/<directoryName>`.
  Future<String?> _legacyRootPath() async {
    try {
      final cache = await getApplicationCacheDirectory();
      return '${cache.path}${Platform.pathSeparator}$_directoryName';
    } catch (_) {
      return null;
    }
  }

  /// Resolves an entry's on-disk path.
  ///
  /// Handles two layout realities:
  /// - the one-time move out of the purgeable Caches directory, and
  /// - multi-file torrents, where the file sits under the torrent's root
  ///   directory (`<cacheKey>/<torrent name>/<file>`) instead of directly in
  ///   the cache-key directory.
  Future<String> _resolveFilePath(String stored, {String? fileName}) async {
    if (stored.isEmpty) return stored;
    if (await File(stored).exists()) return stored;

    var candidate = stored;
    final legacyPath = await _legacyRootPath();
    if (legacyPath != null && stored.startsWith(legacyPath)) {
      final root = await _root();
      candidate = '${root.path}${stored.substring(legacyPath.length)}';
      if (await File(candidate).exists()) return candidate;
    }

    if (fileName != null && fileName.isNotEmpty) {
      final parent = File(candidate).parent;
      try {
        if (await parent.exists()) {
          await for (final entity in parent.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File && entity.uri.pathSegments.last == fileName) {
              return entity.path;
            }
          }
        }
      } catch (_) {}
    }
    return candidate;
  }

  Future<File> _indexFile() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    return File('${support.path}${Platform.pathSeparator}$_indexName');
  }

  Future<int> _rootSize() async => _directorySize(await _root());

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var result = 0;
    await for (final item in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (item is File) {
        try {
          result += await item.length();
        } on FileSystemException {
          // A concurrently removed cache file is simply not counted.
        }
      }
    }
    return result;
  }
}

class _CacheState {
  _CacheState(this.entries, this.preferences);
  final Map<String, PlaybackCacheEntry> entries;
  PlaybackPreferences preferences;

  factory _CacheState.empty() => _CacheState(
    {},
    PlaybackPreferences(maxCacheBytes: PlaybackCacheStore.defaultMaxBytes),
  );

  factory _CacheState.fromJson(Map<String, dynamic> json) {
    final result = _CacheState.empty();
    final entries = json['entries'];
    if (entries is List) {
      for (final raw in entries.whereType<Map>()) {
        try {
          final entry = PlaybackCacheEntry.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (entry.cacheKey.isNotEmpty) result.entries[entry.cacheKey] = entry;
        } catch (_) {}
      }
    }
    final max = (json['maxCacheBytes'] as num?)?.toInt();
    result.preferences = PlaybackPreferences(
      maxCacheBytes: max != null && max > 0
          ? max
          : PlaybackCacheStore.defaultMaxBytes,
      preferredAudioLanguage: json['preferredAudioLanguage'] as String?,
      preferredSubtitleLanguage: json['preferredSubtitleLanguage'] as String?,
    );
    return result;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'maxCacheBytes': preferences.maxCacheBytes,
    'preferredAudioLanguage': preferences.preferredAudioLanguage,
    'preferredSubtitleLanguage': preferences.preferredSubtitleLanguage,
    'entries': entries.values.map((entry) => entry.toJson()).toList(),
  };
}
