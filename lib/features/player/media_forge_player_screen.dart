import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_forge_player/media_forge_player.dart';

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';
import '../../providers/app_providers.dart';
import '../../services/streaming/playback_session.dart';
import '../../services/streaming/source_ranking.dart';
import '../../services/streaming/streaming_service.dart';
import '../../services/streaming/torrent_buffered_ranges.dart';
import '../../services/torrent/native_torrent_engine.dart';
import 'default_player_screen.dart';
import 'player_backend.dart';

/// Experimental MediaForge playback implementation.
///
/// Owns its own torrent session (via [StreamingService]), watch-history
/// resume, and [MediaForgePlayerController]. Never mounted at the same time
/// as [DefaultPlayerScreen]; [PlayerScreen] freezes one backend per open.
/// On init/open failure it falls back to the default player for this
/// session at the preserved position without mutating the persisted setting.
///
/// MediaForge specifics consumed here (never reimplemented):
/// * [mediaForgeBaseConfiguration] at creation (native decode) plus
///   per-source network profiles selected on every open.
/// * [MediaForgePlayerValue.firstFramePresented] gates visual readiness —
///   never non-zero position.
/// * seek generations: only the latest generation drives UI/service/history.
/// * [MediaForgePlayerController.suspend]/`resume` across app lifecycle.
/// * deterministic teardown: player release awaits before torrent stop.
class MediaForgePlayerScreen extends ConsumerStatefulWidget {
  const MediaForgePlayerScreen({
    required this.mediaRef,
    required this.sourceId,
    this.season,
    this.episode,
    this.resumeMs,
    this.initialSource,
    super.key,
  });
  final MediaRef mediaRef;
  final String sourceId;
  final int? season;
  final int? episode;
  final int? resumeMs;
  final TorrentSource? initialSource;

  @override
  ConsumerState<MediaForgePlayerScreen> createState() =>
      _MediaForgePlayerScreenState();
}

class _MediaForgePlayerScreenState
    extends ConsumerState<MediaForgePlayerScreen>
    with WidgetsBindingObserver {
  late final MediaForgePlayerController _controller;
  late final StreamingService _service;
  StreamSubscription<MediaForgeEvent>? _eventsSub;
  StreamSubscription<MediaForgeDiagnostics>? _diagSub;
  PlaybackSessionToken? _sessionToken;
  String? _openedUri;
  bool _openInFlight = false;
  Timer? _saveTimer;
  late final ValueNotifier<MediaPlayerTorrentStats?> _torrentStats;

  /// Playback stage derived from controller value + seek generations.
  /// Updated without setState; the package-owned chrome listens to the
  /// controller itself, so PeerStream chrome never rebuilds the video.
  late final ValueNotifier<MediaForgePlaybackStage> _stage;
  final MediaForgeSeekCoordinator _seekCoordinator = MediaForgeSeekCoordinator();

  /// Retried resume-seek driver (open-resume + history-dialog confirm share
  /// it). Superseded runs cancel via run-id; teardown/fallback cancel
  /// explicitly. Never touches video state itself.
  final MediaForgeResumeSeekDriver _resumeDriver =
      MediaForgeResumeSeekDriver();

  bool _lastBuffering = false;
  bool _askedAboutResume = false;
  bool _fallbackActive = false;
  String? _fallbackReason;
  int? _fallbackResumeMs;
  Object? _lastSeenError;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _lastReportedPositionMs = -1;

  // ---- dispose-safe persist state ----
  //
  // `ref` must never be touched from dispose(). Everything [_persistProgress]
  // and [_resumeTarget] need is cached here while the widget is mounted:
  // the history notifier is held directly (app-scoped, outlives the
  // screen) and entries/details snapshots refresh on every build via
  // `ref.read` (no extra subscriptions, no rebuild coupling).
  late final WatchHistory _watchHistory;
  List<WatchEntry>? _cachedHistory;
  String? _cachedTitle;
  String? _cachedPosterPath;
  String? _cachedBackdropPath;

  // ---- benchmark hooks (transition logging only, never per frame) ----
  MediaForgeSourceType? _openSourceType;
  int _rebufferEvents = 0;
  int _lastSubtitleCuesPending = 0;
  MediaForgeDiagnostics? _lastDiag;

  // ---- torrent cache ranges (timeline availability, never video state) ---
  //
  // True downloaded/verified availability from the torrent session, pushed
  // to the controller as generic `MediaForgeBufferedRange` values. The
  // controller unions them with its internal read-ahead for display; this
  // screen never touches MediaForge internals and never rebuilds video.
  List<MediaForgeBufferedRange> _lastPushedExternalRanges = const [];
  String? _rangesPlaybackId;

  /// Single idempotent release path (player → torrent). Shared by
  /// dispose, route-pop, back navigation, and fallback.
  Future<void>? _releaseFuture;

  @override
  void initState() {
    super.initState();
    _service = ref.read(streamingServiceProvider);
    // New configuration API: native source decode resolution. Per-source
    // network profiles (torrent-localhost / direct-HTTP / cached-file) are
    // selected on every open in [_openIfNeeded].
    _controller = MediaForgePlayerController(
      configuration: mediaForgeBaseConfiguration,
    );
    _controller.addListener(_onControllerValue);
    _eventsSub = _controller.events.listen(_onEvent);
    _diagSub = _controller.diagnostics.listen(_onDiagnostics);
    _torrentStats = ValueNotifier(null);
    _stage = ValueNotifier(MediaForgePlaybackStage.opening);
    _watchHistory = ref.read(watchHistoryProvider.notifier);
    _cachedHistory = ref.read(watchHistoryProvider).value;
    WidgetsBinding.instance.addObserver(this);
    logPlaybackBackend(
      requested: PlayerBackend.mediaForge,
      active: PlayerBackend.mediaForge,
    );
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_controller.value.isPlaying) unawaited(_persistProgress());
    });
    Future<void>.microtask(() => _start());
  }

  // ---------------------------------------------------------- observers ---

  void _onControllerValue() {
    if (_fallbackActive || _releaseFuture != null) return;
    final value = _controller.value;
    _position = value.position;
    _duration = value.duration;
    // Active position hook: recorded for stall accounting/benchmarks,
    // emits no UI state.
    if (value.position.inMilliseconds != _lastReportedPositionMs) {
      _lastReportedPositionMs = value.position.inMilliseconds;
      _service.reportPlaybackPosition(
        value.position.inMilliseconds,
        seekGeneration: value.activeSeekGeneration,
      );
    }
    // First-frame gating: non-zero position is NOT display evidence.
    // Only the player's first-frame confirmation marks playback.
    if (value.firstFramePresented &&
        !value.isBuffering &&
        mounted &&
        _service.state.phase != StreamingPhase.playing &&
        _service.state.playback != null &&
        _service.state.phase != StreamingPhase.error) {
      _service.markPlaying();
      _updatePolling();
    }
    if (value.firstFramePresented &&
        value.isBuffering &&
        !_lastBuffering) {
      _rebufferEvents++;
    }
    if (value.isBuffering != _lastBuffering &&
        _service.state.playback != null) {
      _lastBuffering = value.isBuffering;
      // Player-side buffering/starvation hook.
      _service.reportBuffering(
        value.isBuffering,
        bufferedPositionMs: value.buffered.inMilliseconds,
      );
      _updatePolling();
    }
    _updateStage(value.isBuffering);
    final error = value.errorDescription;
    if (error != null &&
        _openedUri != null &&
        _lastSeenError != error &&
        mounted) {
      _lastSeenError = error;
      _offerFallback(
        'Playback error: $error',
        snack: true,
      );
    }
    // Duration/position moved: re-derive torrent cache ranges (change-gated,
    // no rebuilds).
    _syncTorrentAvailability();
  }

  /// Seek lifecycle + first-frame events from the player.
  void _onEvent(MediaForgeEvent event) {
    if (_fallbackActive || _releaseFuture != null) return;
    switch (event.type) {
      case MediaForgeEventType.firstFramePresented:
        if (mounted && _service.state.playback != null) {
          _service.markPlaying();
          _updatePolling();
        }
        _updateStage(_controller.value.isBuffering);
        logMediaForgeBenchmark(
          buildMediaForgeBenchmarkPayload(
            requested: PlayerBackend.mediaForge,
            active: PlayerBackend.mediaForge,
            sourceType:
                _openSourceType ??
                MediaForgeSourceType.directHttp,
            tapToFirstFrameMs: _service.currentDiagnostics?.tapToFirstFrame
                ?.inMilliseconds,
            firstFrameLatencyMs: event.latencyMs,
            positionMs: event.positionMs,
            note: 'first-frame',
          ),
        );
      case MediaForgeEventType.seekStarted:
        final generation = event.generation;
        _seekCoordinator.onSeekStarted(generation);
        _service.reportSeekStarted(generation: generation);
        _updatePolling();
        _updateStage(_controller.value.isBuffering);
      case MediaForgeEventType.seekSettled:
        final generation = event.generation;
        // Only the latest generation is current; stale completions from
        // rapid seeks are ignored and never overwrite newer state.
        if (!_seekCoordinator.shouldApplySettled(generation)) {
          debugPrint(
            '[Playback] Ignoring stale MediaForge seek settled gen=$generation '
            '(current=${_seekCoordinator.latestStarted})',
          );
          return;
        }
        _seekCoordinator.onSeekSettled(generation);
        _service.reportSeekSettled(generation: generation);
        _updatePolling();
        _updateStage(_controller.value.isBuffering);
        logMediaForgeBenchmark(
          buildMediaForgeBenchmarkPayload(
            requested: PlayerBackend.mediaForge,
            active: PlayerBackend.mediaForge,
            sourceType:
                _openSourceType ??
                MediaForgeSourceType.directHttp,
            lastSeekLatencyMs: event.latencyMs,
            lastSeekGeneration: generation,
            positionMs: event.positionMs,
            note: 'seek-settled',
          ),
        );
      case MediaForgeEventType.buffering:
        _updatePolling();
      case MediaForgeEventType.completed:
        _updateStage(_controller.value.isBuffering);
      case MediaForgeEventType.error:
        if (event.message != null &&
            _openedUri != null &&
            mounted &&
            _lastSeenError != event.message) {
          _lastSeenError = event.message;
          _offerFallback('Playback error: ${event.message}', snack: true);
        }
      case MediaForgeEventType.opened:
      case MediaForgeEventType.playing:
      case MediaForgeEventType.paused:
      case MediaForgeEventType.disposed:
      case MediaForgeEventType.stateChanged:
        break;
    }
  }

  /// Diagnostics snapshots: retained for the teardown summary and for
  /// cue-count tracking. Never rebuilds UI and never polls subtitle text
  /// per frame — cue decoding/timing stays inside the package.
  void _onDiagnostics(MediaForgeDiagnostics diag) {
    if (_fallbackActive || _releaseFuture != null) return;
    _lastDiag = diag;
    _lastSubtitleCuesPending = diag.subtitleCuesPending;
  }

  void _updateStage(bool isBuffering) {
    final value = _controller.value;
    final next = resolveMediaForgeStage(
      hasError: value.hasError,
      isCompleted: value.isCompleted,
      isInitialized: value.isInitialized,
      firstFramePresented: value.firstFramePresented,
      isPlaying: value.isPlaying,
      isBuffering: isBuffering,
      hasPendingSeek: _seekCoordinator.hasPendingSeek,
    );
    if (_stage.value != next) _stage.value = next;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_fallbackActive || _releaseFuture != null) return;
    // Forward lifecycle so the package can suspend its frame pump,
    // diagnostics, subtitle polling, and audio, then resume the same
    // session. Never dispose/recreate across a temporary backgrounding.
    switch (mediaForgeLifecycleAction(state)) {
      case MediaForgeLifecycleAction.suspend:
        unawaited(_controller.suspend());
      case MediaForgeLifecycleAction.resume:
        unawaited(_controller.resume());
    }
  }

  // ------------------------------------------------------------ session ---

  void _updatePolling() {
    final engine = _service.engine;
    if (engine is! NativeTorrentEngine) return;
    final phase = _service.state.phase;
    // Driven by actual playback state (phase, player buffering, latest
    // seek), never by guessed timers.
    if (phase == StreamingPhase.playing &&
        !_lastBuffering &&
        !_seekCoordinator.hasPendingSeek) {
      engine.useSteadyPolling();
    } else {
      engine.useStartupPolling();
    }
  }

  void _cancelOwnedSession() {
    unawaited(_stopOwnedSessionAsync());
  }

  Future<void> _stopOwnedSessionAsync() async {
    final token = _sessionToken;
    _sessionToken = null;
    if (token == null) return;
    token.cancel();
    if (_service.state.sessionId == token.id) {
      try {
        await _service.stop();
      } catch (_) {}
    } else {
      _service.cancelSession(token.id);
    }
  }

  Future<void> _start({Duration? preservePosition}) async {
    _cancelOwnedSession();
    try {
      _openedUri = null;
      await _controller.stop();
      if (!mounted || _fallbackActive || _releaseFuture != null) return;
      final tokenAtEntry = _sessionToken;
      final fastSource = widget.initialSource;
      if (fastSource != null && fastSource.id == widget.sourceId) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (!mounted ||
            _sessionToken != tokenAtEntry ||
            _fallbackActive ||
            _releaseFuture != null) {
          return;
        }
        if (policy.allows(fastSource)) {
          final token = _service.beginSession(fastSource);
          _sessionToken = token;
          _updatePolling();
          await _service.start(fastSource, claimed: token);
          _updatePolling();
          return;
        }
      }
      final cached = await ref
          .read(playbackCacheProvider)
          .lookupRequest(
            widget.mediaRef,
            widget.season,
            widget.episode,
            widget.sourceId,
          );
      if (!mounted ||
          _sessionToken != tokenAtEntry ||
          _fallbackActive ||
          _releaseFuture != null) {
        return;
      }
      final cachedSource = cached?.source;
      if (cachedSource != null) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (!mounted ||
            _sessionToken != tokenAtEntry ||
            _fallbackActive ||
            _releaseFuture != null) {
          return;
        }
        if (policy.allows(cachedSource)) {
          final token = _service.beginSession(cachedSource);
          _sessionToken = token;
          _updatePolling();
          await _service.start(cachedSource, claimed: token);
          _updatePolling();
          return;
        }
      }
      final results = await ref.read(
        sourceResultsProvider((
          media: widget.mediaRef,
          season: widget.season,
          episode: widget.episode,
        )).future,
      );
      if (!mounted ||
          _sessionToken != tokenAtEntry ||
          _fallbackActive ||
          _releaseFuture != null) {
        return;
      }
      final all = results.expand((r) => r.sources).toList();
      var source = all.where((s) => s.id == widget.sourceId).firstOrNull;
      source ??= refreshSource(_placeholderSourceForRefresh(), all);
      if (source == null) {
        _service.reportError(
          'This source is no longer available. Go back and search again.',
        );
        return;
      }
      if (!mounted ||
          _sessionToken != tokenAtEntry ||
          _fallbackActive ||
          _releaseFuture != null) {
        return;
      }
      final token = _service.beginSession(source);
      _sessionToken = token;
      _updatePolling();
      await _service.start(source, claimed: token);
      _updatePolling();
      if (preservePosition != null) _position = preservePosition;
    } catch (error) {
      if (mounted) {
        _service.reportError(
          'Unable to open this source. Go back and search again.',
        );
      }
    }
  }

  TorrentSource _placeholderSourceForRefresh() {
    final fast = widget.initialSource;
    if (fast != null) return fast;
    return TorrentSource(
      id: widget.sourceId,
      content: widget.mediaRef,
      name: widget.sourceId,
      uri: Uri.parse('about:blank'),
      inputType: TorrentInputType.directUrl,
      providerName: '',
      attribution: '',
      license: '',
      provenanceUrl: Uri.parse('about:blank'),
      seasonNumber: widget.season,
      episodeNumber: widget.episode,
    );
  }

  Future<void> _retry() async {
    final resume = _position > Duration.zero ? _position : _explicitStart();
    _openedUri = null;
    _lastSeenError = null;
    _cancelOwnedSession();
    ref.invalidate(
      sourceResultsProvider((
        media: widget.mediaRef,
        season: widget.season,
        episode: widget.episode,
      )),
    );
    ref.invalidate(
      sourceDiscoveryProvider((
        media: widget.mediaRef,
        season: widget.season,
        episode: widget.episode,
      )),
    );
    await _start(preservePosition: resume);
  }

  void _onStreamingState(StreamingState state) {
    // Isolated notifier: torrent-speed updates never rebuild the video.
    _torrentStats.value = MediaPlayerTorrentStats(
      downloadSpeedBps: state.stats.downloadRate,
      uploadSpeedBps: state.stats.uploadRate,
      peers: state.stats.peers ?? 0,
      seeds: state.stats.seeds ?? 0,
      downloadedBytes: state.stats.downloadedBytes,
      totalBytes: state.stats.totalBytes,
      streamBufferMs: state.bufferedPositionMs ?? 0,
    );
    // Torrent availability moved: refresh the timeline cache ranges
    // (change-gated push, never a rebuild).
    _syncTorrentAvailability();
    unawaited(_openIfNeeded(state));
  }

  /// Pushes true torrent cache availability to the player timeline.
  ///
  /// Reads the verified snapshot from the streaming session, converts it to
  /// generic time ranges, and forwards it via
  /// `setExternalBufferedRanges`. MediaForge internals are untouched — the
  /// controller unions these with its own read-ahead for display.
  /// Change-gated (identical ranges are never re-pushed) and rebuild-free.
  void _syncTorrentAvailability() {
    if (_fallbackActive || _releaseFuture != null || !mounted) return;
    final playback = _service.state.playback;
    if (playback == null) {
      _clearPushedRanges();
      return;
    }
    if (_rangesPlaybackId != playback.id) {
      _rangesPlaybackId = playback.id;
      _clearPushedRanges();
    }
    final duration = _controller.value.duration;
    if (duration <= Duration.zero) return;
    final List<MediaForgeBufferedRange> ranges;
    if (playback.fromCache) {
      // Verified complete local file: the whole timeline is available.
      ranges = [
        MediaForgeBufferedRange(start: Duration.zero, end: duration),
      ];
    } else {
      final availability = _service.currentTorrentAvailability();
      // No engine data yet: keep the last pushed ranges, never blank good
      // data on a transient miss.
      if (availability == null) return;
      ranges = torrentAvailabilityToBufferedRanges(
        availability: availability,
        duration: duration,
      );
    }
    if (listEquals(ranges, _lastPushedExternalRanges)) return;
    _lastPushedExternalRanges = ranges;
    _controller.setExternalBufferedRanges(ranges);
  }

  void _clearPushedRanges() {
    if (_lastPushedExternalRanges.isEmpty) return;
    _lastPushedExternalRanges = const [];
    if (_fallbackActive || _releaseFuture != null) return;
    _controller.clearExternalBufferedRanges();
  }

  Future<void> _openIfNeeded(StreamingState state) async {
    if (_fallbackActive || _openInFlight || _releaseFuture != null) return;
    final uri = state.playback?.uri.toString();
    if (!mounted ||
        uri == null ||
        uri == _openedUri ||
        state.phase == StreamingPhase.error) {
      return;
    }
    if (_sessionToken != null && state.sessionId != _sessionToken!.id) return;
    _openInFlight = true;
    _openedUri = uri;
    try {
      await MediaForgeRuntime.ensureInitialized();
    } catch (error) {
      _openInFlight = false;
      debugPrint('[Playback] MediaForge runtime init failed: $error');
      _offerFallback('Rust initialization failed: $error');
      return;
    }
    try {
      final source = state.source;
      final playbackUri = state.playback!.uri;
      final sourceType = classifyMediaForgeSource(playbackUri);
      final profile = mediaForgeNetworkProfileForUri(playbackUri);
      _openSourceType = sourceType;
      final media = buildMediaForgeMedia(
        uri: playbackUri,
        headers: source?.headers ?? const {},
      );
      debugPrint(
        '[Playback] Opening MediaForge ${mediaForgeSourceTypeLabel(sourceType)} '
        'source: $uri (profile=${profile.name}, '
        'timeout=${profile.timeout.inSeconds}s, reconnect=${profile.reconnect})',
      );
      logMediaForgeBenchmark(
        buildMediaForgeBenchmarkPayload(
          requested: PlayerBackend.mediaForge,
          active: PlayerBackend.mediaForge,
          sourceType: sourceType,
          note: 'open',
        ),
      );
      await _controller.open(media, play: true);
      final explicitStart = _explicitStart();
      if (explicitStart != null &&
          mounted &&
          !_fallbackActive &&
          _releaseFuture == null) {
        // Resume seeks retry until they land: a single post-open seek is
        // the flakiest call in torrent playback. Runs in the background so
        // open completion (and the history dialog path below) never waits.
        unawaited(_driveResumeSeek(explicitStart, reason: 'open'));
      }
      unawaited(_maybeHistoryResume());
    } catch (error) {
      debugPrint('[Playback] MediaForge open failed: $error');
      _offerFallback('Open failed: $error');
    } finally {
      _openInFlight = false;
    }
  }

  /// Session-level fallback: dispose MediaForge, reopen the same source at
  /// the preserved position with the default player. Never mutates the
  /// persisted `useMediaForgePlayer` preference.
  void _offerFallback(String reason, {bool snack = true}) {
    if (_fallbackActive) return;
    final posMs = _controller.value.position.inMilliseconds;
    final explicitMs = _explicitStart()?.inMilliseconds;
    _fallbackResumeMs = resolveFallbackResumeMs(
      controllerPositionMs: posMs,
      explicitStartMs: explicitMs,
      widgetResumeMs: widget.resumeMs,
    );
    _fallbackReason = reason;
    _fallbackActive = true;
    // A resume drive must not keep seeking the released controller.
    _resumeDriver.cancel();
    logPlaybackBackend(
      requested: PlayerBackend.mediaForge,
      active: PlayerBackend.defaultPlayer,
      reason: reason,
    );
    logMediaForgeBenchmark(
      buildMediaForgeBenchmarkPayload(
        requested: PlayerBackend.mediaForge,
        active: PlayerBackend.defaultPlayer,
        sourceType:
            _openSourceType ?? MediaForgeSourceType.directHttp,
        positionMs: _fallbackResumeMs,
        note: 'fallback: $reason',
      ),
    );
    // Hand session ownership to the default screen: it begins its own
    // session (clearing the shared service state) on mount. The torrent
    // session is intentionally NOT stopped here; only the MediaForge
    // player is released (idempotent with [_release]).
    _sessionToken = null;
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(_eventsSub?.cancel());
    _eventsSub = null;
    unawaited(_diagSub?.cancel());
    _diagSub = null;
    _controller.removeListener(_onControllerValue);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    unawaited(_controller.release());
    if (mounted) {
      setState(() {});
      if (snack) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'MediaForge failed to start — using default player',
              ),
            ),
          );
      }
    }
  }

  Duration? _explicitStart() {
    if (_fallbackResumeMs != null && _fallbackResumeMs! > 0) {
      return Duration(milliseconds: _fallbackResumeMs!);
    }
    final explicit = widget.resumeMs;
    if (explicit == null || explicit <= 0) {
      return _position > Duration.zero ? _position : null;
    }
    if (explicit < watchTrivialPositionMs) return null;
    return Duration(milliseconds: explicit);
  }

  Future<void> _maybeHistoryResume() async {
    if (widget.resumeMs != null && widget.resumeMs! > 0) return;
    if (_askedAboutResume || !mounted) return;
    final target = _resumeTarget();
    if (target == null) return;
    _askedAboutResume = true;
    final resume = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Continue watching?'),
        content: Text('Resume from ${formatWatchTimestamp(target)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Start over'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
    if (resume == true &&
        mounted &&
        !_fallbackActive &&
        _releaseFuture == null) {
      // Same retry policy as the open-resume path: one flaky seek must not
      // strand playback at 0:00.
      unawaited(_driveResumeSeek(target, reason: 'history-dialog'));
    }
  }

  /// Drives a resume seek to [target] until it lands, is superseded by a
  /// newer (user) seek, or exhausts its budget. Never throws; never touches
  /// video state. Failed attempts void their generation so neither the
  /// seeking stage nor history saves can latch forever.
  Future<void> _driveResumeSeek(Duration target, {required String reason}) {
    final uriAtStart = _openedUri;
    return _resumeDriver.drive(
      reason: reason,
      target: target,
      seek: _controller.seek,
      currentGeneration: () => _controller.seekGeneration,
      latestStarted: () => _seekCoordinator.latestStarted,
      latestSettled: () => _seekCoordinator.latestSettled,
      position: () => _controller.value.position,
      isCurrent: () =>
          mounted &&
          !_fallbackActive &&
          _releaseFuture == null &&
          _openedUri == uriAtStart,
      onAttemptFailed: (generation) {
        // Only void when no newer seek arrived mid-attempt; otherwise the
        // newer seek owns the state and this run is already obsolete.
        if (generation != _seekCoordinator.latestStarted) return;
        _seekCoordinator.onSeekFailed(generation);
        _service.reportSeekSettled(generation: generation);
        _updateStage(_controller.value.isBuffering);
      },
    );
  }

  Duration? _resumeTarget() {
    final explicit = widget.resumeMs;
    int? targetMs = explicit != null && explicit > 0 ? explicit : null;
    targetMs ??= _cachedHistory
        ?.where((entry) => entry.key == watchKey(
              widget.mediaRef,
              widget.season,
              widget.episode,
            ))
        .firstOrNull
        ?.positionMs;
    if (targetMs == null || targetMs < watchTrivialPositionMs) return null;
    final target = Duration(milliseconds: targetMs);
    if (_duration > Duration.zero &&
        targetMs >= _duration.inMilliseconds * watchFinishedProgress) {
      return null;
    }
    return target;
  }

  /// Dispose-safe: uses only [_service] and the cached history/details
  /// snapshots — never `ref`, so calling this from dispose() is safe.
  Future<void> _persistProgress({bool allowPendingSeek = false}) async {
    final positionMs = _position.inMilliseconds;
    if (positionMs <= 0 || _fallbackActive) return;
    // Periodic ticks never record mid-seek (only settled generations count),
    // but teardown saves must not be dropped: a pending — possibly stuck —
    // seek must never erase the last-known position needed for reopen resume.
    if (_seekCoordinator.hasPendingSeek && !allowPendingSeek) return;
    final source = _service.state.source;
    if (source == null) return;
    final durationMs = _duration.inMilliseconds;
    final key = watchKey(widget.mediaRef, widget.season, widget.episode);
    final existing = _cachedHistory?.where((entry) {
      return entry.key == key;
    }).firstOrNull;
    String title = existing?.title ?? source.fileNameHint ?? source.name;
    String? posterPath = existing?.posterPath;
    String? backdropPath = existing?.backdropPath;
    final cachedTitle = _cachedTitle;
    if (cachedTitle != null) {
      title = cachedTitle;
      posterPath = _cachedPosterPath;
      backdropPath = _cachedBackdropPath;
    }
    final entry = buildWatchPersistEntry(
      positionMs: positionMs,
      durationMs: durationMs,
      key: key,
      media: widget.mediaRef,
      title: title,
      posterPath: posterPath,
      backdropPath: backdropPath,
      season: widget.season,
      episode: widget.episode,
      sourceId: source.id,
      providerName: source.providerName,
      sourceUri: source.uri.toString(),
      inputType: source.inputType.name,
    );
    if (entry == null) return;
    if (entry.isFinished) {
      await _watchHistory.remove(key);
      return;
    }
    if (entry.isTrivial) return;
    await _watchHistory.save(entry);
  }

  Future<Uri?> _pickExternalSubtitle() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa'],
        dialogTitle: 'Choose subtitle file',
      );
      final path = result?.files.singleOrNull?.path;
      if (path == null) return null;
      return Uri.file(path);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ teardown ---

  /// One idempotent release path. Ordered: stop UI interaction → release
  /// the MediaForge player (textures/native resources included) → stop
  /// the owned torrent session. The route leaves separately, always last.
  /// On fallback the torrent session is owned by the default screen and is
  /// left alone.
  Future<void> _release() {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    final future = _releaseImpl();
    _releaseFuture = future;
    return future;
  }

  Future<void> _releaseImpl() async {
    // 1. Stop UI interaction.
    _saveTimer?.cancel();
    _saveTimer = null;
    // Stop any in-flight resume-seek drive first: it must not issue seeks
    // against a controller being torn down.
    _resumeDriver.cancel();
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _controller.removeListener(_onControllerValue);
    try {
      await _eventsSub?.cancel();
    } catch (_) {}
    _eventsSub = null;
    try {
      await _diagSub?.cancel();
    } catch (_) {}
    _diagSub = null;
    // 2-3. Release the MediaForge player (idempotent in the package) and
    // its textures/native resources BEFORE touching the torrent session,
    // so FFmpeg is never still reading when the server shuts down.
    await runMediaForgeTeardown(
      releasePlayer: () => _controller.release(),
      stopTorrent: () async {
        if (!_fallbackActive) await _stopOwnedSessionAsync();
      },
    );
    final diag = _lastDiag;
    logMediaForgeBenchmark(
      buildMediaForgeBenchmarkPayload(
        requested: PlayerBackend.mediaForge,
        active: _fallbackActive
            ? PlayerBackend.defaultPlayer
            : PlayerBackend.mediaForge,
        sourceType:
            _openSourceType ?? MediaForgeSourceType.directHttp,
        presentedFps: diag?.presentedFps,
        decodedFps: diag?.decodedFps,
        droppedFrames: diag?.droppedFrames,
        avDriftMs: diag?.avDriftMs,
        activeDecoder: diag?.activeDecoder,
        renderingPath: diag?.renderingPath,
        rebufferEvents: _rebufferEvents,
        stallEvents: _service.currentDiagnostics?.stallEvents,
        subtitleCuesPending: _lastSubtitleCuesPending,
        positionMs: _position.inMilliseconds,
        note: 'teardown',
      ),
    );
    _torrentStats.dispose();
    _stage.dispose();
  }

  Future<void> _handleBack() async {
    unawaited(_persistProgress(allowPendingSeek: true));
    await _release();
    if (mounted && context.mounted) context.pop();
  }

  @override
  void dispose() {
    unawaited(_persistProgress(allowPendingSeek: true));
    // Idempotent: safe alongside PopScope/back/fallback releases.
    unawaited(_release());
    super.dispose();
  }

  // ---------------------------------------------------------------- build ---

  @override
  Widget build(BuildContext context) {
    ref.listen(streamingStateProvider, (_, next) {
      next.whenData(_onStreamingState);
    });
    if (_fallbackActive) {
      return DefaultPlayerScreen(
        mediaRef: widget.mediaRef,
        sourceId: widget.sourceId,
        season: widget.season,
        episode: widget.episode,
        resumeMs: _fallbackResumeMs ?? widget.resumeMs,
        initialSource: widget.initialSource,
      );
    }
    // Rebuild isolation: watch only phase/playback/message slices so
    // torrent-speed and stats ticks (served via [_torrentStats]) never
    // rebuild the texture/video subtree. Position/buffered updates arrive
    // through the controller listener with no setState.
    final phase = ref.watch(
      streamingStateProvider.select(
        (s) => s.value?.phase ?? _service.state.phase,
      ),
    );
    final playback = ref.watch(
      streamingStateProvider.select((s) => s.value?.playback),
    );
    final streamMessage = ref.watch(
      streamingStateProvider.select((s) => s.value?.message),
    );
    final details = ref.watch(detailsProvider(widget.mediaRef));
    // Refresh dispose-safe persist snapshots. `ref.read` here subscribes to
    // nothing, so history saves (every 5s) still never rebuild the video.
    _cachedHistory = ref.read(watchHistoryProvider).value ?? _cachedHistory;
    details.whenData((value) {
      _cachedTitle = value.item.title;
      _cachedPosterPath = value.item.posterPath;
      _cachedBackdropPath = value.item.backdropPath;
    });
    final mediaTitle = details.when(
      data: (value) => value.item.title,
      loading: () => 'Player',
      error: (_, _) => 'Player',
    );
    final episodeLabel =
        widget.mediaRef.type == MediaType.tv &&
            widget.season != null &&
            widget.episode != null
        ? 'S${widget.season} E${widget.episode}'
        : null;

    if (phase == StreamingPhase.unsupported) {
      return Scaffold(
        appBar: AppBar(title: Text(mediaTitle)),
        body: Center(
          child: Text(streamMessage ?? 'Playback is not supported here.'),
        ),
      );
    }
    if (phase == StreamingPhase.error) {
      return Scaffold(
        appBar: AppBar(title: const Text('MediaForge (Experimental)')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 40),
                const SizedBox(height: 12),
                Text(streamMessage ?? 'Streaming failed.'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Go back'),
                ),
                if (_fallbackReason != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _offerFallback(
                      _fallbackReason!,
                      snack: false,
                    ),
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Retry with default player'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (playback == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('MediaForge (Experimental)')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return PopScope(
      onPopInvokedWithResult: (_, _) {
        unawaited(_persistProgress(allowPendingSeek: true));
        unawaited(_release());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: MediaPlayerScreen(
            controller: _controller,
            title: mediaTitle,
            subtitle: 'MediaForge • ${episodeLabel ?? playback.file.name}',
            torrentStats: _torrentStats,
            onPickExternalSubtitle: _pickExternalSubtitle,
            onRetry: _retry,
            onBack: () => unawaited(_handleBack()),
          ),
        ),
      ),
    );
  }
}
