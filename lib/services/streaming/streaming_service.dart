import 'dart:async';

import '../../models/torrent_models.dart';
import '../playback/playback_cache.dart';
import '../torrent/torrent_engine.dart';

enum StreamingPhase {
  idle,
  resolving,
  buffering,
  ready,
  playing,
  seeking,
  stopped,
  error,
  unsupported,
}

enum PlaybackOrigin { network, cache }

class StreamingState {
  const StreamingState({
    this.phase = StreamingPhase.idle,
    this.source,
    this.playback,
    this.stats = const TorrentStats(),
    this.message,
    this.origin = PlaybackOrigin.network,
    this.sessionId = 0,
  });
  final StreamingPhase phase;
  final TorrentSource? source;
  final TorrentPlaybackStream? playback;
  final TorrentStats stats;
  final String? message;
  final PlaybackOrigin origin;
  final int sessionId;

  StreamingState copyWith({
    StreamingPhase? phase,
    TorrentSource? source,
    TorrentPlaybackStream? playback,
    TorrentStats? stats,
    String? message,
    PlaybackOrigin? origin,
    int? sessionId,
  }) => StreamingState(
    phase: phase ?? this.phase,
    source: source ?? this.source,
    playback: playback ?? this.playback,
    stats: stats ?? this.stats,
    message: message,
    origin: origin ?? this.origin,
    sessionId: sessionId ?? this.sessionId,
  );
}

class StreamingService {
  StreamingService(this._engine, [PlaybackCacheStore? cache])
    : _cache = cache ?? PlaybackCacheStore();
  final TorrentEngine _engine;
  final PlaybackCacheStore _cache;
  final _controller = StreamController<StreamingState>.broadcast();
  StreamingState _state = const StreamingState();
  TorrentHandle? _handle;
  int _generation = 0;
  StreamSubscription<TorrentStats>? _statsSubscription;
  Timer? _stallTimer;

  StreamingState get state => _state;
  Stream<StreamingState> get states => _controller.stream;
  bool get isSupported => _engine.isSupported;
  String? get unsupportedReason => _engine.unsupportedReason;

  Future<void> warmUp() async {
    try {
      await _engine.initialize();
    } catch (_) {}
  }

  void _emit(StreamingState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  Future<int> start(TorrentSource source) async {
    final generation = ++_generation;
    await _clearSession(keepFiles: true);
    if (generation != _generation) return generation;
    if (source.inputType == TorrentInputType.directUrl) {
      _emit(
        StreamingState(
          phase: StreamingPhase.ready,
          source: source,
          playback: TorrentPlaybackStream(
            id: source.id,
            uri: source.uri,
            file: TorrentFileEntry(
              index: 0,
              name: source.fileNameHint ?? source.name,
              size: source.sizeBytes ?? 0,
              isStreamable: true,
            ),
          ),
          sessionId: generation,
        ),
      );
      return generation;
    }
    if (!_engine.isSupported) {
      _emit(
        StreamingState(
          phase: StreamingPhase.unsupported,
          source: source,
          message: _engine.unsupportedReason,
          sessionId: generation,
        ),
      );
      return generation;
    }
    final local = await _cache.completeFile(source);
    if (local != null) {
      _emit(
        StreamingState(
          phase: StreamingPhase.ready,
          source: source,
          playback: TorrentPlaybackStream(
            id: 'cache-${local.cacheKey}',
            uri: Uri.file(local.filePath),
            file: local.file,
            fromCache: true,
          ),
          origin: PlaybackOrigin.cache,
          sessionId: generation,
        ),
      );
      return generation;
    }
    _emit(
      StreamingState(
        phase: StreamingPhase.resolving,
        source: source,
        sessionId: generation,
      ),
    );
    try {
      final handle = await _engine.add(source);
      if (generation != _generation) {
        await _engine.stop(handle, deleteFiles: false);
        return generation;
      }
      _handle = handle;
      _statsSubscription = _engine
          .watch(handle)
          .listen(
            (stats) {
              if (generation != _generation ||
                  _state.phase == StreamingPhase.error) {
                return;
              }
              var phase = _state.phase;
              if (stats.phase == 'seeking') phase = StreamingPhase.seeking;
              if (stats.phase == 'buffering') phase = StreamingPhase.buffering;
              if (stats.phase == 'ready' &&
                  _state.playback != null &&
                  phase != StreamingPhase.playing) {
                phase = StreamingPhase.ready;
              }
              _emit(_state.copyWith(phase: phase, stats: stats));
            },
            onError: (Object error) {
              if (generation == _generation) {
                reportError('Torrent transfer failed: $error');
              }
            },
          );
      final files = await _engine.waitForFiles(handle);
      if (generation != _generation) {
        return generation;
      }
      final selected = source.fileIndex == null
          ? selectVideoFile(files, hint: source.fileNameHint)
          : files
                .where((f) => f.index == source.fileIndex && f.isStreamable)
                .firstOrNull;
      if (selected == null) {
        throw StateError(
          'The requested video file is missing from this torrent.',
        );
      }
      if (source.episodeNumber != null &&
          source.fileIndex == null &&
          source.fileNameHint == null) {
        throw StateError(
          'Episode source is missing its video file selection. Choose another source.',
        );
      }
      _emit(_state.copyWith(phase: StreamingPhase.buffering));
      final playback = await _engine.startStream(handle, selected);
      if (generation != _generation) return generation;
      _emit(
        _state.copyWith(phase: StreamingPhase.buffering, playback: playback),
      );
      unawaited(_cache.record(source, selected, complete: false, byteSize: 0));
      _startStallCheck(generation, _state.stats.downloadedBytes);
    } catch (error) {
      if (generation != _generation) return generation;
      await _clearSession();
      if (generation != _generation) return generation;
      _emit(
        _state.copyWith(phase: StreamingPhase.error, message: error.toString()),
      );
    }
    return generation;
  }

  void markPlaying() {
    _stallTimer?.cancel();
    _stallTimer = null;
    if (_state.playback != null && _state.phase != StreamingPhase.error) {
      _emit(_state.copyWith(phase: StreamingPhase.playing));
    }
  }

  void reportError(String message) =>
      _emit(_state.copyWith(phase: StreamingPhase.error, message: message));

  Future<void> stop() async {
    final generation = ++_generation;
    await _clearSession(keepFiles: true);
    if (generation == _generation) {
      _emit(const StreamingState(phase: StreamingPhase.stopped));
    }
  }

  Future<void> _clearSession({bool keepFiles = true}) async {
    _stallTimer?.cancel();
    _stallTimer = null;
    final subscription = _statsSubscription;
    _statsSubscription = null;
    final handle = _handle;
    _handle = null;
    await subscription?.cancel();
    final source = _state.source;
    final playback = _state.playback;
    if (keepFiles &&
        source != null &&
        playback != null &&
        !playback.fromCache &&
        source.inputType != TorrentInputType.directUrl) {
      try {
        await _cache.record(
          source,
          playback.file,
          complete: _state.stats.progress >= 0.999,
          byteSize: _state.stats.downloadedBytes,
        );
      } catch (_) {}
    }
    if (handle != null) {
      try {
        await _engine.stop(handle, deleteFiles: !keepFiles);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await stop();
    await _engine.dispose();
    await _controller.close();
  }

  void _startStallCheck(int generation, int initialDownloadedBytes) {
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(minutes: 5), () async {
      if (generation != _generation ||
          _state.phase == StreamingPhase.playing ||
          _state.phase == StreamingPhase.error) {
        return;
      }

      final bytesReceived =
          _state.stats.downloadedBytes - initialDownloadedBytes;
      final tooSlow = _state.stats.downloadRate < 1024;
      if (bytesReceived >= 64 * 1024 || !tooSlow) return;

      final peers = _state.stats.peers;
      final peerDetail = peers == null ? '' : ' ($peers connected peers)';
      await _clearSession();
      if (generation != _generation) return;
      _emit(
        _state.copyWith(
          phase: StreamingPhase.error,
          message:
              'This source did not deliver enough video data after five minutes$peerDetail. Retry or choose another source.',
        ),
      );
    });
  }
}
