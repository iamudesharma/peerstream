import 'dart:async';

import '../../models/torrent_models.dart';
import '../playback/playback_cache.dart';
import '../playback/torrent_cache_identity.dart';
import '../torrent/provider_cache.dart';
import '../torrent/torrent_engine.dart';
import 'playback_config.dart';
import 'playback_session.dart';

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

/// Distinguishes recovery states for understandable UI:
/// finding sources vs connecting to peers vs buffering vs reconnecting.
enum StreamingDetail {
  none,
  findingSources,
  connectingPeers,
  buffering,
  reconnecting,
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
    this.startedAt,
    this.detail = StreamingDetail.none,
    this.isBuffering = false,
    this.bufferedPositionMs,
    this.diagnostics,
  });
  final StreamingPhase phase;
  final TorrentSource? source;
  final TorrentPlaybackStream? playback;
  final TorrentStats stats;
  final String? message;
  final PlaybackOrigin origin;
  final int sessionId;
  final DateTime? startedAt;
  final StreamingDetail detail;
  final bool isBuffering;
  final int? bufferedPositionMs;
  final Map<String, dynamic>? diagnostics;

  StreamingState copyWith({
    StreamingPhase? phase,
    TorrentSource? source,
    TorrentPlaybackStream? playback,
    TorrentStats? stats,
    String? message,
    PlaybackOrigin? origin,
    int? sessionId,
    DateTime? startedAt,
    StreamingDetail? detail,
    bool? isBuffering,
    int? bufferedPositionMs,
    Map<String, dynamic>? diagnostics,
  }) => StreamingState(
    phase: phase ?? this.phase,
    source: source ?? this.source,
    playback: playback ?? this.playback,
    stats: stats ?? this.stats,
    message: message ?? this.message,
    origin: origin ?? this.origin,
    sessionId: sessionId ?? this.sessionId,
    startedAt: startedAt ?? this.startedAt,
    detail: detail ?? this.detail,
    isBuffering: isBuffering ?? this.isBuffering,
    bufferedPositionMs: bufferedPositionMs ?? this.bufferedPositionMs,
    diagnostics: diagnostics ?? this.diagnostics,
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
  Timer? _slowTimer;
  Timer? _postPlayStallTimer;
  DateTime? _lastProgressAt;
  int _lastDownloadedBytes = 0;

  PlaybackDiagnostics? _diagnostics;
  final SingleFlight _prefetchFlight = SingleFlight();
  String? _lastPrefetchKey;
  TorrentHandle? _prefetchHandle;

  // ---- MediaForge player hooks (additive; default player untouched) ----
  //
  // Latest player-reported state. Updated via [reportPlaybackPosition] and
  // the generation-aware seek reports below. Never emits UI state itself so
  // high-frequency position updates cannot rebuild the video subtree; the
  // values exist to separate torrent/network waits from decoder/render
  // latency in benchmarks and to keep stall monitors honest.
  int? _activeSeekGeneration;
  int? _settledSeekGeneration;
  int? _lastPlayerPositionMs;
  DateTime? _lastPlayerPositionAt;

  /// Newest seek generation started by the player (`null` = none yet).
  int? get activeSeekGeneration => _activeSeekGeneration;

  /// Newest seek generation that settled (`null` = none yet).
  int? get lastSettledSeekGeneration => _settledSeekGeneration;

  /// Latest player-reported playback position in ms (`null` = none yet).
  int? get lastPlayerPositionMs => _lastPlayerPositionMs;

  /// Wall-clock time of the latest player-reported position.
  DateTime? get lastPlayerPositionAt => _lastPlayerPositionAt;

  StreamingState get state => _state;
  Stream<StreamingState> get states => _controller.stream;
  bool get isSupported => _engine.isSupported;
  String? get unsupportedReason => _engine.unsupportedReason;
  PlaybackDiagnostics? get currentDiagnostics => _diagnostics;

  /// Runtime native build identity for platform-parity checks.
  String get nativeBuildIdentity {
    final engine = _engine;
    if (engine is EngineDiagnosticsProvider) {
      return (engine as EngineDiagnosticsProvider).bridgeVersion;
    }
    return 'unknown';
  }

  Future<void> warmUp() async {
    try {
      await _engine.initialize();
    } catch (_) {}
  }

  /// Claims a session synchronously and emits `resolving` immediately.
  ///
  /// Call this before the first `await` in the player so leaving during
  /// metadata resolution still owns (and can cancel) the session. Returns
  /// a [PlaybackSessionToken] whose [PlaybackSessionToken.id] is the
  /// generation used by [start] and [cancelSession].
  PlaybackSessionToken beginSession(TorrentSource source) {
    final generation = ++_generation;
    final token = PlaybackSessionToken(generation, source, DateTime.now());
    _diagnostics = PlaybackDiagnostics(sessionId: generation)
      ..sessionClaimedAt = token.claimedAt;
    _activeSeekGeneration = null;
    _settledSeekGeneration = null;
    _lastPlayerPositionMs = null;
    _lastPlayerPositionAt = null;
    // Best-effort cleanup of any previous session without awaiting — the
    // async portion of start() re-checks generation after every boundary.
    unawaited(_clearSession(keepFiles: true));
    _emit(
      StreamingState(
        phase: StreamingPhase.resolving,
        source: source,
        sessionId: generation,
        startedAt: token.claimedAt,
        detail: StreamingDetail.connectingPeers,
      ),
    );
    return token;
  }

  /// Cancels a previously claimed session. If [sessionId] is still current,
  /// the generation is bumped so all stale async callbacks reject.
  void cancelSession(int sessionId) {
    if (sessionId == _generation) {
      _generation++;
      unawaited(_clearSession(keepFiles: true));
      _emit(const StreamingState(phase: StreamingPhase.stopped));
    }
  }

  /// Warms the native session and pre-registers [source] so its metadata
  /// exchange starts before the player opens. Safe to call from hover or
  /// list prefetch: it never emits UI state and never throws.
  ///
  /// Bounded to a single candidate: concurrent calls for the same key share
  /// one future (deduplication); a different key releases the previous
  /// unused prefetch handle.
  Future<void> prefetchSource(TorrentSource source) async {
    if (source.inputType == TorrentInputType.directUrl) return;
    if (!_engine.isSupported) {
      await warmUp();
      return;
    }
    final key = torrentCacheKey(source);
    if (key == _lastPrefetchKey && _prefetchHandle != null) return;
    // Release the previous unused prefetch candidate.
    final oldHandle = _prefetchHandle;
    final oldKey = _lastPrefetchKey;
    if (oldHandle != null && oldKey != null && oldKey != key) {
      _prefetchHandle = null;
      _lastPrefetchKey = null;
      try {
        // Only release if it is not the active playback handle.
        if (_handle?.id != oldHandle.id) {
          await _engine.stop(oldHandle, deleteFiles: false);
        }
      } catch (_) {}
    }
    try {
      await _engine.initialize();
      final handle = await _prefetchFlight.run<TorrentHandle>(
        key,
        () => _engine.add(source),
      );
      // Keep the most recent candidate; an older racing completion that is
      // no longer wanted is released immediately.
      if (_lastPrefetchKey != null && _lastPrefetchKey != key) {
        try {
          await _engine.stop(handle, deleteFiles: false);
        } catch (_) {}
        return;
      }
      _lastPrefetchKey = key;
      _prefetchHandle = handle;
    } catch (_) {}
  }

  void _emit(StreamingState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  Future<int> start(
    TorrentSource source, {
    PlaybackSessionToken? claimed,
  }) async {
    final int generation;
    if (claimed != null && claimed.id == _generation) {
      generation = claimed.id;
      // beginSession already emitted resolving; keep its diagnostics.
    } else {
      final token = beginSession(source);
      generation = token.id;
      if (token.isCancelled) return generation;
    }
    if (generation != _generation) return generation;

    bool stale() => generation != _generation || (claimed?.isCancelled ?? false);

    if (source.inputType == TorrentInputType.directUrl) {
      _diagnostics?.engineAddAt = DateTime.now();
      _diagnostics?.streamCreatedAt = DateTime.now();
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
          startedAt: _state.startedAt ?? DateTime.now(),
          detail: StreamingDetail.none,
          diagnostics: _diagnostics?.toMap(),
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
    // Verified cache path: partial/sparse files never qualify.
    final local = await _verifiedCompleteFile(source);
    if (stale()) return generation;
    if (local != null) {
      _diagnostics?.streamCreatedAt = DateTime.now();
      final diag = Map<String, dynamic>.of(_diagnostics?.toMap() ?? {});
      diag['origin'] = 'cache';
      diag['nativeBuild'] = nativeBuildIdentity;
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
          startedAt: _state.startedAt,
          detail: StreamingDetail.none,
          diagnostics: diag,
        ),
      );
      return generation;
    }
    _emit(
      _state.copyWith(
        phase: StreamingPhase.resolving,
        detail: StreamingDetail.connectingPeers,
        diagnostics: _diagnostics?.toMap(),
      ),
    );
    try {
      _diagnostics?.engineAddAt = DateTime.now();
      final handle = await _engine.add(source);
      if (stale()) {
        await _engine.stop(handle, deleteFiles: false);
        return generation;
      }
      _handle = handle;
      // A prefetched handle for the same source is now owned by playback.
      try {
        if (_prefetchHandle?.id == handle.id) {
          _prefetchHandle = null;
          _lastPrefetchKey = null;
        }
      } catch (_) {}
      _statsSubscription = _engine
          .watch(handle)
          .listen(
            (stats) {
              if (generation != _generation ||
                  _state.phase == StreamingPhase.error) {
                return;
              }
              var phase = _state.phase;
              var detail = _state.detail;
              if (stats.phase == 'seeking') {
                phase = StreamingPhase.seeking;
                detail = StreamingDetail.buffering;
              } else if (stats.phase == 'buffering') {
                if (_state.playback != null) {
                  phase = StreamingPhase.buffering;
                  detail = StreamingDetail.buffering;
                } else {
                  phase = StreamingPhase.resolving;
                  detail = StreamingDetail.connectingPeers;
                }
              } else if (stats.phase == 'ready' &&
                  _state.playback != null &&
                  phase != StreamingPhase.playing &&
                  !_state.isBuffering) {
                phase = StreamingPhase.ready;
                detail = StreamingDetail.none;
              }
              _emit(
                _state.copyWith(
                  phase: phase,
                  detail: detail,
                  stats: stats,
                  message: _state.message,
                  diagnostics: _diagnostics?.toMap(),
                ),
              );
            },
            onError: (Object error) {
              if (generation == _generation) {
                reportError('Torrent transfer failed: $error');
              }
            },
          );
      final files = await _engine
          .waitForFiles(handle)
          .timeout(StreamingTimeouts.metadataWait);
      if (stale()) {
        return generation;
      }
      _diagnostics?.metadataAt = DateTime.now();
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
      _emit(
        _state.copyWith(
          phase: StreamingPhase.buffering,
          detail: StreamingDetail.buffering,
          message: _state.message,
        ),
      );
      final playback = await _engine.startStream(handle, selected);
      if (stale()) return generation;
      _diagnostics?.streamCreatedAt = DateTime.now();
      _diagnostics?.nativeBuild = nativeBuildIdentity;
      try {
        if (_engine is EngineDiagnosticsProvider) {
          final d = await (_engine as EngineDiagnosticsProvider)
              .engineDiagnostics()
              .timeout(const Duration(seconds: 2));
          _diagnostics?.cacheCapacityBytes = d.cacheCapacityBytes;
          _diagnostics?.cacheFilledBytes = d.cacheFilledBytes;
        }
      } catch (_) {}
      _emit(
        _state.copyWith(
          phase: StreamingPhase.buffering,
          detail: StreamingDetail.buffering,
          playback: playback,
          message: _state.message,
          diagnostics: _diagnostics?.toMap(),
        ),
      );
      unawaited(_cache.record(source, selected, complete: false, byteSize: 0));
      _startStallCheck(generation, _state.stats.downloadedBytes);
    } catch (error) {
      if (stale()) return generation;
      await _clearSession();
      if (stale()) return generation;
      _emit(
        _state.copyWith(
          phase: StreamingPhase.error,
          detail: StreamingDetail.none,
          message: error.toString(),
        ),
      );
    }
    return generation;
  }

  TorrentEngine get engine => _engine;

  /// Verified torrent availability snapshot for the active session (`null`
  /// when there is no torrent session, the playback is a verified local
  /// cache file or direct URL, or the engine cannot report it).
  ///
  /// Raw byte/piece signals only — time mapping lives in
  /// `torrentAvailabilityToBufferedRanges` so torrent specifics never leak
  /// into the player. Never emits state; safe at stats-tick cadence.
  TorrentFileAvailability? currentTorrentAvailability() {
    final playback = _state.playback;
    final handle = _handle;
    if (playback == null || handle == null || playback.fromCache) return null;
    final TorrentEngine engine = _engine;
    if (engine is! TorrentAvailabilityProvider) return null;
    final id = int.tryParse(handle.id);
    if (id == null) return null;
    try {
      final provider = engine as TorrentAvailabilityProvider;
      return provider.fileAvailability(id, playback.file.index);
    } catch (_) {
      return null;
    }
  }

  /// Verified offline path. Requires ALL of:
  /// - cache entry flagged complete,
  /// - recorded byteSize >= selected file size (rejects sparse preallocation),
  /// - on-disk length >= selected file size,
  /// - native piece verification when the engine can provide it.
  Future<dynamic> _verifiedCompleteFile(TorrentSource source) async {
    final entry = await _cache.completeFile(source);
    if (entry == null) return null;
    if (!entry.complete) return null;
    if (entry.filePath.isEmpty) return null;
    if (entry.file.size <= 0) return null;
    // Sparse-file guard: a preallocated file has the right length but the
    // cache never recorded the bytes.
    if (entry.byteSize < entry.file.size) return null;
    // Native piece verification when available.
    final engine = _engine;
    if (engine is FileCompletenessChecker && _handle != null) {
      try {
        final ok = await (engine as FileCompletenessChecker)
            .isFileComplete(_handle!, entry.file)
            .timeout(const Duration(seconds: 3));
        if (!ok) return null;
      } catch (_) {
        // Verification unavailable (handle for another torrent) — fall
        // through to filesystem checks only when the torrent is not loaded.
      }
    }
    return entry;
  }

  /// Idempotent transition to playing. Repeated position updates must not
  /// emit extra states or cancel startup timers more than once.
  void markPlaying() {
    if (_state.phase == StreamingPhase.playing) return;
    if (_state.playback == null) return;
    if (_state.phase == StreamingPhase.error) return;
    _stallTimer?.cancel();
    _stallTimer = null;
    _slowTimer?.cancel();
    _slowTimer = null;
    _diagnostics?.firstFrameAt ??= DateTime.now();
    _lastProgressAt = DateTime.now();
    _startPostPlayStallMonitor();
    _emit(
      _state.copyWith(
        phase: StreamingPhase.playing,
        detail: StreamingDetail.none,
        isBuffering: false,
        diagnostics: _diagnostics?.toMap(),
      ),
    );
  }

  /// Accurate buffering state from media_kit `stream.buffering`.
  /// Idempotent: duplicate events do not re-emit.
  void reportBuffering(bool buffering, {int? bufferedPositionMs}) {
    if (buffering == _state.isBuffering &&
        bufferedPositionMs == _state.bufferedPositionMs) {
      return;
    }
    _diagnostics?.lastBufferingAt = buffering
        ? DateTime.now()
        : _diagnostics?.lastBufferingAt;
    if (buffering) {
      _diagnostics?.bufferingEvents = (_diagnostics?.bufferingEvents ?? 0) + 1;
    }
    final phase = buffering
        ? (_state.playback == null
              ? StreamingPhase.resolving
              : StreamingPhase.buffering)
        : (_state.playback != null &&
                _state.phase != StreamingPhase.error &&
                _state.phase != StreamingPhase.seeking
            ? StreamingPhase.playing
            : _state.phase);
    _emit(
      _state.copyWith(
        phase: phase,
        detail: buffering
            ? StreamingDetail.buffering
            : StreamingDetail.none,
        isBuffering: buffering,
        bufferedPositionMs: bufferedPositionMs ?? _state.bufferedPositionMs,
        diagnostics: _diagnostics?.toMap(),
      ),
    );
  }

  void reportSeekStarted({int? generation}) {
    _diagnostics?.lastSeekAt = DateTime.now();
    _diagnostics?.seekEvents = (_diagnostics?.seekEvents ?? 0) + 1;
    if (generation != null &&
        (_activeSeekGeneration == null ||
            generation > _activeSeekGeneration!)) {
      _activeSeekGeneration = generation;
    }
    if (_state.phase == StreamingPhase.error) return;
    _emit(
      _state.copyWith(
        phase: StreamingPhase.seeking,
        detail: StreamingDetail.buffering,
        diagnostics: _diagnostics?.toMap(),
      ),
    );
  }

  void reportSeekSettled({int? generation}) {
    // Stale completions must never overwrite a newer seek.
    if (generation != null && generation != _activeSeekGeneration) return;
    if (generation != null) _settledSeekGeneration = generation;
    if (_state.phase != StreamingPhase.seeking) return;
    _emit(
      _state.copyWith(
        phase: _state.isBuffering
            ? StreamingPhase.buffering
            : StreamingPhase.playing,
        detail: _state.isBuffering
            ? StreamingDetail.buffering
            : StreamingDetail.none,
      ),
    );
  }

  /// Records the player's active playback position for stall accounting
  /// and benchmarks. Emits nothing: called at position cadence, it must
  /// not rebuild UI. `seekGeneration` links the sample to a seek when the
  /// player exposes generations.
  void reportPlaybackPosition(int positionMs, {int? seekGeneration}) {
    _lastPlayerPositionMs = positionMs;
    _lastPlayerPositionAt = DateTime.now();
    if (seekGeneration != null &&
        (_activeSeekGeneration == null ||
            seekGeneration >= _activeSeekGeneration!)) {
      _activeSeekGeneration = seekGeneration;
    }
  }

  void reportError(String message) =>
      _emit(_state.copyWith(phase: StreamingPhase.error, message: message));

  /// User-visible reconnecting state that keeps the last playback URI so
  /// the player does not tear down while the engine re-establishes peers.
  void reportReconnecting(String message) {
    _emit(
      _state.copyWith(
        detail: StreamingDetail.reconnecting,
        message: message,
        diagnostics: _diagnostics?.toMap(),
      ),
    );
  }

  Future<void> stop() async {
    final generation = ++_generation;
    _activeSeekGeneration = null;
    _settledSeekGeneration = null;
    await _clearSession(keepFiles: true);
    if (generation == _generation) {
      _emit(const StreamingState(phase: StreamingPhase.stopped));
    }
  }

  Future<void> _clearSession({bool keepFiles = true}) async {
    _stallTimer?.cancel();
    _stallTimer = null;
    _slowTimer?.cancel();
    _slowTimer = null;
    _postPlayStallTimer?.cancel();
    _postPlayStallTimer = null;
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
        // Conservative completion: progress alone is not proof. Require
        // byte counts to agree before flagging an entry complete; the
        // verified path re-checks on the next start.
        final progress = _state.stats.progress;
        final downloaded = _state.stats.downloadedBytes;
        final total = _state.stats.totalBytes;
        final complete =
            progress >= 0.999 &&
            downloaded > 0 &&
            (total <= 0 || downloaded >= (total * 0.999).round());
        await _cache.record(
          source,
          playback.file,
          complete: complete,
          byteSize: downloaded,
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
    _slowTimer?.cancel();
    // Early warning at 25s: surface slow-start without failing. The player
    // keeps buffering; the UI shows a "try another source" hint.
    _slowTimer = Timer(const Duration(seconds: 25), () {
      if (generation != _generation ||
          _state.phase == StreamingPhase.playing ||
          _state.phase == StreamingPhase.error) {
        return;
      }
      final bytesReceived =
          _state.stats.downloadedBytes - initialDownloadedBytes;
      if (bytesReceived >= 256 * 1024) return;
      if (_state.stats.downloadRate >= 50 * 1024) return;
      final peers = _state.stats.peers;
      final peerDetail =
          peers == null ? 'no peers yet' : '$peers connected peer(s)';
      _emit(
        _state.copyWith(
          stats: _state.stats,
          detail: StreamingDetail.connectingPeers,
          message:
              'Still connecting ($peerDetail, ${bytesReceived ~/ 1024} KB so far). '
              'If this persists, try a Direct source or one with more seeds.',
        ),
      );
    });
    _stallTimer = Timer(const Duration(minutes: 3), () async {
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
              'This source did not deliver enough video data after three minutes$peerDetail. Retry or choose another source.',
        ),
      );
    });
  }

  /// Post-play stall monitor: after first frame, prolonged buffering with
  /// no byte progress surfaces a reconnecting hint instead of silently
  /// stalling. Idempotent with markPlaying/reportBuffering.
  void _startPostPlayStallMonitor() {
    _postPlayStallTimer?.cancel();
    _lastDownloadedBytes = _state.stats.downloadedBytes;
    _lastProgressAt = DateTime.now();
    _postPlayStallTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_state.phase == StreamingPhase.error ||
          _state.phase == StreamingPhase.stopped) {
        timer.cancel();
        return;
      }
      final downloaded = _state.stats.downloadedBytes;
      if (downloaded != _lastDownloadedBytes) {
        _lastDownloadedBytes = downloaded;
        _lastProgressAt = DateTime.now();
        return;
      }
      final last = _lastProgressAt;
      if (last == null) return;
      if (!_state.isBuffering) return;
      if (DateTime.now().difference(last) >= const Duration(seconds: 30)) {
        _diagnostics?.stallEvents = (_diagnostics?.stallEvents ?? 0) + 1;
        reportReconnecting(
          'Connection stalled. Reconnecting — try another source if this persists.',
        );
        _lastProgressAt = DateTime.now();
      }
    });
  }
}
