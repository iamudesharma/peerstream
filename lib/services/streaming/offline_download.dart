import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/torrent_models.dart';
import '../playback/playback_cache.dart';
import '../playback/torrent_cache_identity.dart';
import '../playback/playback_cache_models.dart';
import '../experience/playback_experience.dart';
import '../torrent/torrent_engine.dart';
import 'direct_video_transfer.dart';
import '../torrent/source_policy_loader.dart';

enum OfflinePhase { preparing, downloading, paused, complete, error }

class OfflineJob {
  const OfflineJob(
    this.source,
    this.phase, {
    this.bytes = 0,
    this.total = 0,
    this.message,
  });
  final TorrentSource source;
  final OfflinePhase phase;
  final int bytes;
  final int total;
  final String? message;
}

/// One explicit transfer, sharing native resources only while playback is idle.
class OfflineDownload {
  OfflineDownload(this.engine, this.cache, {PlaybackExperience? journal})
    : _journal = journal ?? playbackExperience;
  final PlaybackExperience _journal;
  bool _restored = false;
  Future<void> restoreIntent() async {
    if (_restored) return;
    await _journal.load();
    if (_journal.loadError != null) return;
    _restored = true;
    final raw = _journal.section('offlineIntent');
    if (state.value != null) return;
    TorrentSource? source;
    if (raw.isNotEmpty) {
      try {
        source = PlaybackCacheEntry.fromJson(raw).source;
      } catch (_) {}
    }
    source ??= (await cache.entries())
        .where((entry) => entry.pinned && !entry.complete)
        .firstOrNull
        ?.source;
    if (source != null && state.value == null) {
      userPaused = true;
      state.value = OfflineJob(
        source,
        OfflinePhase.paused,
        message: 'Resume your saved request',
      );
    }
  }

  Future<void> _intent(TorrentSource? source) async {
    final entry = source == null
        ? null
        : PlaybackCacheEntry(
            cacheKey: torrentCacheKey(source),
            source: source,
            file: const TorrentFileEntry(
              index: 0,
              name: '',
              size: 0,
              isStreamable: false,
            ),
            filePath: '',
            complete: false,
            byteSize: 0,
            lastUsedAt: DateTime.now(),
          );
    await _journal.update((data) {
      if (entry == null) {
        data.remove('offlineIntent');
      } else {
        data['offlineIntent'] = entry.toJson();
      }
    });
  }

  final _direct = DirectVideoTransfer();
  final TorrentEngine engine;
  final PlaybackCacheStore cache;
  final state = ValueNotifier<OfflineJob?>(null);
  TorrentHandle? _handle;
  TorrentFileEntry? _file;
  StreamSubscription<TorrentStats>? _stats;
  Timer? _poll;
  Future<void> _tail = Future.value();
  bool _checking = false;
  bool userPaused = false;
  bool _disposed = false;
  int _generation = 0;
  Completer<void>? _cancelPreparation;
  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> save(TorrentSource source, {required bool playbackActive}) =>
      _serialize(() async {
        if (_disposed) return;
        if (source.inputType != TorrentInputType.directUrl &&
            engine is! OfflineDownloadController) {
          throw StateError(
            'Offline saving is available for torrent sources on this device.',
          );
        }
        final current = state.value;
        if (current != null &&
            torrentCacheKey(current.source) != torrentCacheKey(source) &&
            current.phase != OfflinePhase.complete) {
          throw StateError('Finish or cancel the current offline save first.');
        }
        if (current != null &&
            torrentCacheKey(current.source) == torrentCacheKey(source) &&
            (current.phase == OfflinePhase.preparing ||
                current.phase == OfflinePhase.downloading)) {
          return;
        }
        // A failed stop retains ownership so a retry cannot orphan a writer.
        if (_handle != null) await _release();
        await _intent(source);
        userPaused = false;
        if (playbackActive) {
          state.value = OfflineJob(
            source,
            OfflinePhase.paused,
            message: 'Waiting until playback stops',
          );
          return;
        }
        await _start(source);
      });
  Future<void> _start(TorrentSource source) async {
    final generation = ++_generation;
    _file = null;
    state.value = OfflineJob(source, OfflinePhase.preparing);
    if (source.inputType == TorrentInputType.directUrl) {
      await _startDirect(source, generation);
      return;
    }
    final cancel = Completer<void>();
    _cancelPreparation = cancel;
    try {
      await engine.initialize();
      final handle = await engine.add(source);
      _handle = handle;
      final files = await Future.any([
        engine.waitForFiles(handle),
        cancel.future.then<List<TorrentFileEntry>>(
          (_) => throw const _PreparationCancelled(),
        ),
      ]);
      if (generation != _generation) throw const _PreparationCancelled();
      final file = source.fileIndex == null
          ? selectVideoFile(files, hint: source.fileNameHint)
          : files.firstWhere((f) => f.index == source.fileIndex);
      _file = file;
      final limit = (await cache.preferences()).maxCacheBytes;
      final otherPinned = (await cache.entries())
          .where((e) => e.pinned && e.cacheKey != torrentCacheKey(source))
          .fold<int>(0, (sum, e) => sum + e.file.size);
      if (otherPinned + file.size > limit) {
        throw StateError(
          'This save exceeds your storage budget. Remove an offline save or increase the limit.',
        );
      }
      await cache.record(
        source,
        file,
        complete: false,
        byteSize: 0,
        preserveComplete: true,
      );
      await cache.setPinned(torrentCacheKey(source), true);
      await _intent(null);
      await (engine as OfflineDownloadController).downloadFile(handle, file);
      if (generation != _generation) return;
      state.value = OfflineJob(
        source,
        OfflinePhase.downloading,
        total: file.size,
      );
      _stats = engine
          .watch(handle)
          .listen(
            (stats) {
              if (generation != _generation || _disposed) return;
              state.value = OfflineJob(
                source,
                OfflinePhase.downloading,
                bytes: stats.downloadedBytes.clamp(0, file.size),
                total: file.size,
              );
            },
            onError: (Object error) {
              unawaited(
                pause(message: 'Download stopped. Reconnect storage or retry.')
                    .catchError((Object _) {}),
              );
            },
          );
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_checking || generation != _generation) return;
        _checking = true;
        unawaited(
          _serialize(() => _verify(source, handle, file, generation))
              .whenComplete(() => _checking = false),
        );
      });
    } catch (error) {
      try {
        await _release();
      } catch (_) {
        state.value = OfflineJob(
          source,
          OfflinePhase.error,
          message: 'Could not stop the download. Retry after reconnecting.',
        );
        rethrow;
      }
      if (error is _PreparationCancelled) return;
      state.value = OfflineJob(
        source,
        OfflinePhase.error,
        message: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> _startDirect(TorrentSource source, int generation) async {
    try {
      if (!(await loadSourcePolicy()).allows(source)) {
        throw StateError('This source is blocked by your source settings.');
      }
      final existing = await cache.completeFile(source);
      if (generation != _generation) return;
      if (existing != null) {
        await cache.setPinned(torrentCacheKey(source), true);
        await _intent(null);
        state.value = OfflineJob(
          source,
          OfflinePhase.complete,
          bytes: existing.file.size,
          total: existing.file.size,
        );
        return;
      }
      final limit = (await cache.preferences()).maxCacheBytes;
      final reserved = (await cache.entries())
          .where((e) => e.pinned && e.cacheKey != torrentCacheKey(source))
          .fold<int>(0, (sum, e) => sum + e.file.size);
      final budget = limit - reserved;
      if (budget <= 0) {
        throw StateError('Remove a saved video or increase the storage limit.');
      }
      final extension =
          RegExp(
                r'\.(mp4|mkv|webm|mov|avi|m4v|ts|mpeg|mpg)$',
                caseSensitive: false,
              )
              .firstMatch(source.fileNameHint ?? source.uri.path)
              ?.group(1)
              ?.toLowerCase() ??
          'video';
      final name = 'video.$extension';
      final directory = await cache.directoryPathFor(source);
      _file = TorrentFileEntry(
        index: 0,
        name: name,
        size: 0,
        isStreamable: true,
      );
      await cache.record(
        source,
        _file!,
        complete: false,
        byteSize: 0,
        preserveComplete: true,
      );
      await cache.setPinned(torrentCacheKey(source), true);
      if (generation != _generation) return;
      var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      unawaited(
        _direct
            .download(
              source.uri,
              '$directory/$name',
              maxBytes: budget,
              headers: source.headers,
              progress: (bytes, total) {
                if (generation != _generation || _disposed) return;
                _file = TorrentFileEntry(
                  index: 0,
                  name: name,
                  size: total,
                  isStreamable: true,
                );
                final now = DateTime.now();
                if (now.difference(lastUpdate).inMilliseconds < 200 &&
                    bytes != total) {
                  return;
                }
                lastUpdate = now;
                state.value = OfflineJob(
                  source,
                  OfflinePhase.downloading,
                  bytes: bytes,
                  total: total,
                );
              },
            )
            .then(
              (bytes) => _serialize(() async {
                if (generation != _generation || _disposed) return;
                _file = TorrentFileEntry(
                  index: 0,
                  name: name,
                  size: bytes,
                  isStreamable: true,
                );
                await cache.record(
                  source,
                  _file!,
                  complete: true,
                  byteSize: bytes,
                );
                await _intent(null);
                state.value = OfflineJob(
                  source,
                  OfflinePhase.complete,
                  bytes: bytes,
                  total: bytes,
                );
              }),
            )
            .catchError((Object error) async {
              if (generation != _generation || _disposed) return;
              state.value = OfflineJob(
                source,
                OfflinePhase.error,
                message: error is StateError
                    ? error.message.toString()
                    : 'Download interrupted. Reconnect storage or retry.',
              );
            }),
      );
    } catch (error) {
      if (generation == _generation) {
        state.value = OfflineJob(
          source,
          OfflinePhase.error,
          message: error is StateError
              ? error.message.toString()
              : 'Could not start the download. Check the source and storage.',
        );
      }
      rethrow;
    }
  }

  Future<void> _verify(
    TorrentSource source,
    TorrentHandle handle,
    TorrentFileEntry file,
    int generation,
  ) async {
    try {
      final complete =
          engine is FileCompletenessChecker &&
          await (engine as FileCompletenessChecker).isFileComplete(
            handle,
            file,
          );
      if (generation != _generation) return;
      await cache.record(
        source,
        file,
        complete: complete,
        byteSize: complete ? file.size : state.value?.bytes ?? 0,
      );
      if (complete) {
        if (generation != _generation) return;
        await _release();
        state.value = OfflineJob(
          source,
          OfflinePhase.complete,
          bytes: file.size,
          total: file.size,
        );
      }
    } catch (_) {
      if (generation == _generation || identical(_handle, handle)) {
        try {
          await _release();
        } catch (_) {
          // Keep the handle for an explicit retry; periodic work is stopped.
        }
        state.value = OfflineJob(
          source,
          OfflinePhase.error,
          message: 'Saving stopped. Check the storage drive.',
        );
      }
    }
  }

  Future<void> pause({bool byUser = true, String? message}) {
    if (_cancelPreparation?.isCompleted == false) {
      _cancelPreparation!.complete();
    }
    return _serialize(() async {
      userPaused = byUser;
      final current = state.value;
      if (current == null || current.phase == OfflinePhase.complete) return;
      final file = _file;
      Object? failure;
      StackTrace? trace;
      try {
        if (file != null) {
          await cache.record(
            current.source,
            file,
            complete: false,
            byteSize: current.bytes,
            preserveComplete: true,
          );
        }
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      // Disk-full or removed-storage metadata failures must not keep traffic
      // running after Pause. A failed native stop remains retryable.
      try {
        await _release();
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      state.value = OfflineJob(
        current.source,
        failure == null ? OfflinePhase.paused : OfflinePhase.error,
        bytes: current.bytes,
        total: current.total,
        message: failure == null
            ? message
            : 'Saving stopped with an error. Reconnect storage and retry.',
      );
      if (failure != null) Error.throwWithStackTrace(failure, trace!);
    });
  }

  Future<void> resume({required bool playbackActive}) async {
    final current = state.value;
    if (current != null) {
      await save(current.source, playbackActive: playbackActive);
    }
  }

  Future<void> cancel() {
    if (_cancelPreparation?.isCompleted == false) {
      _cancelPreparation!.complete();
    }
    return _serialize(() async {
      final current = state.value;
      await _release();
      if (current != null) {
        try {
          await cache.setPinned(torrentCacheKey(current.source), false);
        } catch (_) {}
      }
      if (current != null) await _intent(null);
      state.value = null;
      userPaused = true;
    });
  }

  Future<void> _release() async {
    ++_generation;
    await _direct.cancel();
    _poll?.cancel();
    _poll = null;
    await _stats?.cancel();
    _stats = null;
    final handle = _handle;
    if (handle != null) {
      await engine.stop(handle, deleteFiles: false);
      if (engine is InactiveHandleReleaser) {
        await (engine as InactiveHandleReleaser).releaseInactive(handle);
      }
      _handle = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await pause();
    } catch (_) {}
    state.dispose();
  }
}

class _PreparationCancelled implements Exception {
  const _PreparationCancelled();
}
