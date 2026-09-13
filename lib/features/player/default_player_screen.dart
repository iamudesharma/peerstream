import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/badges.dart';
import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';
import '../../providers/app_providers.dart';
import '../../providers/player_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/settings/settings_store.dart';
import '../../services/playback/playback_cache.dart';
import '../../services/playback/playback_cache_models.dart';
import '../../services/streaming/playback_config.dart';
import '../../services/streaming/playback_session.dart';
import '../../services/streaming/source_ranking.dart';
import '../../services/streaming/streaming_service.dart';
import '../../services/subtitles/subtitle_provider.dart';
import '../../services/subtitles/subtitle_store.dart';
import '../../services/torrent/native_torrent_engine.dart';
import '../statistics/torrent_statistics.dart';
import 'live_player_tracks.dart';
import 'player_shortcuts.dart';

class DefaultPlayerScreen extends ConsumerStatefulWidget {
  const DefaultPlayerScreen({
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
  ConsumerState<DefaultPlayerScreen> createState() =>
      _DefaultPlayerScreenState();
}

class _DefaultPlayerScreenState extends ConsumerState<DefaultPlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  StreamSubscription<double>? _rateSubscription;
  StreamSubscription<double>? _volumeSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  String? _openedUri;
  StreamSubscription<String>? _errorSubscription;
  late final StreamingService _service;
  double _rate = 1;
  double _volume = 100;
  BoxFit _fit = BoxFit.contain;
  double? _aspectRatio;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _isBuffering = false;
  Timer? _saveTimer;
  Timer? _byteObservationTimer;
  Duration? _pendingSeek;
  int _seekAttempts = 0;
  bool _seekInFlight = false;
  DateTime? _openedAt;
  final SubtitleFileStore _subtitleFiles = SubtitleFileStore();
  bool _trackPreferencesApplied = false;
  bool _subtitleSearching = false;
  bool _askedAboutResume = false;
  PlaybackSessionToken? _sessionToken;

  /// Captured so progress can persist from [dispose], where `ref` is unsafe.
  late final WatchHistory _history;
  late final PlaybackCacheStore _cacheStore;
  String? _detailsTitle;
  String? _detailsPosterPath;
  String? _detailsBackdropPath;
  double _lastVolume = 100;
  SubtitleTrack? _lastSubtitleTrack;
  bool _completed = false;
  bool _showStats = false;
  bool _storedPrefsApplied = false;
  bool _resumeGated = false;
  String? _hudLabel;
  IconData? _hudIcon;
  Timer? _hudTimer;
  Timer? _volumeSaveTimer;
  Timer? _rateSaveTimer;
  Timer? _resumeGateTimer;
  int? _nextEpisodeSeason;
  int? _nextEpisodeNumber;
  bool _resolvingNextEpisode = false;
  StreamSubscription<bool>? _completedSubscription;

  @override
  void initState() {
    super.initState();
    _service = ref.read(streamingServiceProvider);
    _history = ref.read(watchHistoryProvider.notifier);
    _cacheStore = ref.read(playbackCacheProvider);
    _player = ref.read(mediaKitPlayerProvider);
    _errorSubscription = _player.stream.error.listen((error) {
      if (mounted) {
        _service.reportError('Playback failed. Try another source or retry.');
      }
    });
    _videoController = ref.read(mediaKitVideoControllerProvider);
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (!playing) {
        unawaited(_persistProgress());
      }
    });
    // Accurate buffering state: media_kit exposes buffering + buffered
    // position. Feed both into the service idempotently; position ticks
    // alone must not flip phase or cancel startup timers repeatedly.
    _bufferingSubscription = _player.stream.buffering.listen((buffering) {
      _isBuffering = buffering;
      _service.reportBuffering(
        buffering,
        bufferedPositionMs: _buffered.inMilliseconds,
      );
      _updatePolling();
      if (mounted) setState(() {});
    });
    _bufferSubscription = _player.stream.buffer.listen((buffer) {
      _buffered = buffer;
      // Report buffered progress without forcing a phase flip when unchanged.
      _service.reportBuffering(
        _isBuffering,
        bufferedPositionMs: buffer.inMilliseconds,
      );
    });
    _tracksSubscription = _player.stream.tracks.listen((tracks) {
      unawaited(_applyTrackPreferences(tracks));
    });
    _rateSubscription = _player.stream.rate.listen((rate) {
      if (mounted) setState(() => _rate = rate);
      _scheduleRateSave(rate);
    });
    _volumeSubscription = _player.stream.volume.listen((volume) {
      if (volume > 0) _lastVolume = volume;
      if (mounted) setState(() => _volume = volume);
      _scheduleVolumeSave(volume);
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (!mounted) return;
      setState(() => _completed = completed);
      if (completed) unawaited(_resolveNextEpisode());
    });
    _positionSubscription = _player.stream.position.listen((position) {
      _position = position;
      // Only transition once: the service is idempotent, but avoid even
      // calling it on every tick after playback begins.
      if (position > Duration.zero &&
          mounted &&
          !_isBuffering &&
          _service.state.phase != StreamingPhase.playing) {
        _service.markPlaying();
        _updatePolling();
      }
      _settlePendingSeek();
    });
    _durationSubscription = _player.stream.duration.listen((duration) {
      _duration = duration;
      _service.reportDurationMs(duration.inMilliseconds);
      _settlePendingSeek();
    });
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_player.state.playing) unawaited(_persistProgress());
    });
    Future<void>.microtask(_start);
  }

  void _updatePolling() {
    // Fast polling during startup/seeking, relaxed during steady playback.
    final engine = _service.engine;
    if (engine is! NativeTorrentEngine) return;
    final phase = _service.state.phase;
    if (phase == StreamingPhase.playing && !_isBuffering) {
      engine.useSteadyPolling();
    } else {
      engine.useStartupPolling();
    }
  }

  void _cancelOwnedSession() {
    final token = _sessionToken;
    _sessionToken = null;
    if (token != null) {
      token.cancel();
      _service.cancelSession(token.id);
    }
  }

  Future<void> _start({Duration? preservePosition}) async {
    // Cancel any previous attempt so rapidly switching sources never leaks.
    _cancelOwnedSession();
    try {
      final settings = await ref.read(appSettingsProvider.future);
      if (!mounted) return;
      _applyStoredPlaybackPreferences(settings);
      setState(() {
        _completed = false;
        _nextEpisodeSeason = null;
        _nextEpisodeNumber = null;
      });
      _openedUri = null;
      _pendingSeek = preservePosition ?? _positionOrExplicit();
      _seekAttempts = 0;
      _seekInFlight = false;
      _resumeGated = false;
      _openedAt = null;
      _trackPreferencesApplied = false;
      _askedAboutResume = false;
      await _player.stop();
      if (!mounted) {
        return;
      }
      final tokenAtEntry = _sessionToken;
      // Learned time→byte anchors from previous playthroughs. These replace
      // the average-bitrate estimate for the resume hint, which VBR files can
      // throw off by tens of MB.
      final cacheEntry = await ref
          .read(playbackCacheProvider)
          .lookupRequest(
            widget.mediaRef,
            widget.season,
            widget.episode,
            widget.sourceId,
          );
      if (!mounted || _sessionToken != tokenAtEntry) return;
      final learnedAnchors =
          cacheEntry?.timeBytePoints ?? const <TimeBytePoint>[];
      // Fast path: source passed via router extra — skip addon re-query
      // (saves 1x IMDb + Nx addon RTTs on every Play tap).
      final fastSource = widget.initialSource;
      if (fastSource != null && fastSource.id == widget.sourceId) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (!mounted || _sessionToken != tokenAtEntry) return;
        if (policy.allows(fastSource)) {
          if (!mounted) return;
          final token = _service.beginSession(fastSource);
          _sessionToken = token;
          _updatePolling();
          await _service.start(
            fastSource,
            claimed: token,
            startPositionMs: _pendingSeek?.inMilliseconds,
            durationMs: _resumeDurationMs(),
            timeBytePoints: learnedAnchors,
          );
          _updatePolling();
          return;
        }
      }
      final cached = cacheEntry;
      if (!mounted || _sessionToken != tokenAtEntry) return;
      final cachedSource = cached?.source;
      debugPrint(
        '[Playback] cache lookup sourceId=${widget.sourceId} '
        'hit=${cachedSource != null} complete=${cached?.complete} '
        'bytes=${cached?.byteSize}',
      );
      if (cachedSource != null) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (!mounted || _sessionToken != tokenAtEntry) return;
        if (policy.allows(cachedSource)) {
          if (!mounted) return;
          final token = _service.beginSession(cachedSource);
          _sessionToken = token;
          _updatePolling();
          await _service.start(
            cachedSource,
            claimed: token,
            startPositionMs: _pendingSeek?.inMilliseconds,
            durationMs: _resumeDurationMs(),
            timeBytePoints: learnedAnchors,
          );
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
      if (!mounted || _sessionToken != tokenAtEntry) {
        return;
      }
      final all = results.expand((r) => r.sources).toList();
      var source = all.where((s) => s.id == widget.sourceId).firstOrNull;
      // Refresh expired direct URLs: the route-provided id may point at a
      // stale expiring URL. Fall back to the best ranked alternative rather
      // than failing outright.
      source ??= refreshSource(_placeholderSourceForRefresh(), all);
      if (source == null) {
        _service.reportError(
          'This source is no longer available. Go back and search again.',
        );
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('That source expired — pick a fresh one.'),
              ),
            );
          context.go(
            Uri(
              path: '/sources/${widget.mediaRef.routeKey}',
              queryParameters: {
                if (widget.season != null) 'season': '${widget.season}',
                if (widget.episode != null) 'episode': '${widget.episode}',
              },
            ).toString(),
          );
        }
        return;
      }
      if (!mounted || _sessionToken != tokenAtEntry) return;
      final token = _service.beginSession(source);
      _sessionToken = token;
      _updatePolling();
      await _service.start(
        source,
        claimed: token,
        startPositionMs: _pendingSeek?.inMilliseconds,
        durationMs: _resumeDurationMs(),
        timeBytePoints: learnedAnchors,
      );
      _updatePolling();
    } catch (_) {
      if (mounted) {
        _service.reportError(
          'Unable to open this source. Go back and search again.',
        );
      }
    }
  }

  TorrentSource _placeholderSourceForRefresh() {
    // Minimal placeholder carrying the requested id so refreshSource() can
    // match by id first, then provider, then global rank.
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

  Duration? _positionOrExplicit() {
    final explicit = _explicitStart();
    if (explicit != null) return explicit;
    if (_position > Duration.zero) return _position;
    return null;
  }

  Future<void> _retry() async {
    // Preserve viewing position across retry; refresh expired direct URLs
    // via a fresh discovery round instead of reusing the stale route source.
    final resume = _position > Duration.zero ? _position : _explicitStart();
    _pendingSeek = resume;
    _seekAttempts = 0;
    _seekInFlight = false;
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

  Future<void> _openIfNeeded(StreamingState state) async {
    final uri = state.playback?.uri.toString();
    if (!mounted ||
        uri == null ||
        uri == _openedUri ||
        state.phase == StreamingPhase.error) {
      return;
    }
    // Reject stale callbacks from a previous session.
    if (_sessionToken != null && state.sessionId != _sessionToken!.id) {
      return;
    }
    _openedUri = uri;
    _trackPreferencesApplied = false;
    // Resolve the resume position *before* opening so playback never starts
    // from zero and then jumps. The history prompt (only when the route has
    // no explicit `resume`) is answered while the source is still loading.
    final resumeStart = await _resolveResumeStart();
    if (!mounted || _openedUri != uri) return;
    if (_sessionToken != null && state.sessionId != _sessionToken!.id) {
      return;
    }
    _openedAt = DateTime.now();
    debugPrint(
      '[Playback] Opening ${state.origin.name} source'
      '${resumeStart == null ? '' : ' at ${resumeStart.inMilliseconds}ms'}',
    );
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        // Separate tuning profiles: direct HTTP, local torrent HTTP, and
        // completed files have different latency/throughput trade-offs.
        final profile = PlayerProfile.forOrigin(
          state.origin == PlaybackOrigin.cache,
          state.source?.inputType == TorrentInputType.directUrl,
        );
        try {
          await native.setProperty(
            'network-timeout',
            profile.networkTimeoutSecs,
          );
        } catch (_) {}
        try {
          await native.setProperty(
            'demuxer-max-bytes',
            profile.demuxerMaxBytes,
          );
        } catch (_) {}
        try {
          await native.setProperty('cache-secs', profile.cacheSecs);
        } catch (_) {}
        try {
          await native.setProperty(
            'demuxer-readahead-secs',
            profile.readaheadSecs,
          );
        } catch (_) {}
      }
      await _player.open(
        Media(uri, httpHeaders: state.source?.headers, start: resumeStart),
        // Resuming opens paused: the settle loop confirms or applies the
        // resume position and only then starts playback, so a resume can
        // never visibly play from zero.
        play: resumeStart == null,
      );
      if (resumeStart != null) {
        _pendingSeek = resumeStart;
        _seekAttempts = 0;
        _seekInFlight = false;
        _resumeGated = true;
        // Watchdog: never leave the player paused forever if the stream
        // reports no position/duration events at all.
        _resumeGateTimer?.cancel();
        _resumeGateTimer = Timer(const Duration(seconds: 45), () {
          if (!mounted || !_resumeGated) return;
          debugPrint('[Playback] Resume gate watchdog fired');
          _pendingSeek = null;
          _finishResume(resumeStart, landed: false);
        });
        _settlePendingSeek();
      }
    } catch (_) {
      if (mounted) {
        _service.reportError(
          'The video could not be opened. Try another source.',
        );
      }
    }
  }

  Duration? _explicitStart() {
    final explicit = widget.resumeMs;
    if (explicit == null || explicit <= 0) return null;
    if (explicit < watchTrivialPositionMs) return null;
    return Duration(milliseconds: explicit);
  }

  /// Resume position to apply at open time, or null for a fresh start.
  ///
  /// Explicit route values win; otherwise the saved history position is
  /// offered once via the "Continue watching?" prompt.
  Future<Duration?> _resolveResumeStart() async {
    final explicit = _explicitStart();
    if (explicit != null) return explicit;
    final pending = _pendingSeek;
    if (pending != null) return pending;
    if (_askedAboutResume || !mounted) return null;
    final target = _resumeTarget();
    if (target == null) return null;
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
    return resume == true ? target : null;
  }

  int? _resumeTargetMs() {
    final explicit = widget.resumeMs;
    if (explicit != null && explicit > 0) return explicit;
    final key = watchKey(widget.mediaRef, widget.season, widget.episode);
    final position = ref
        .read(watchHistoryProvider)
        .value
        ?.where((entry) {
          return entry.key == key;
        })
        .firstOrNull
        ?.positionMs;
    if (position == null || position <= 0) return null;
    return position;
  }

  /// Duration of the last playthrough of this episode, used to map the resume
  /// position to a byte offset for the torrent scheduler. Null when unknown.
  int? _resumeDurationMs() {
    final key = watchKey(widget.mediaRef, widget.season, widget.episode);
    final duration = ref
        .read(watchHistoryProvider)
        .value
        ?.where((entry) {
          return entry.key == key;
        })
        .firstOrNull
        ?.durationMs;
    if (duration == null || duration <= 0) return null;
    return duration;
  }

  Duration? _resumeTarget() {
    final targetMs = _resumeTargetMs();
    if (targetMs == null) return null;
    if (targetMs < watchTrivialPositionMs) return null;
    final target = Duration(milliseconds: targetMs);
    if (_duration > Duration.zero) {
      if (targetMs >= _duration.inMilliseconds * watchFinishedProgress) {
        return null;
      }
    }
    return target;
  }

  void _settlePendingSeek() {
    final target = _pendingSeek;
    if (target == null || !mounted) return;
    // Serialize resume operations: one seek in flight at a time.
    if (_seekInFlight) return;

    // Success first: the open-time `start` may already have positioned the
    // player, and that can be confirmed before duration is known.
    if (resumeSeekLanded(_position, target)) {
      _pendingSeek = null;
      _seekInFlight = false;
      _service.reportSeekSettled();
      debugPrint(
        '[Playback] Resume settled at ${_position.inMilliseconds}ms '
        '(target ${target.inMilliseconds}ms)',
      );
      // Learn the real byte offset for this position while the read head is
      // still at the seek target.
      _scheduleByteObservation(target);
      _finishResume(target, landed: true);
      return;
    }

    final timedOut =
        _openedAt != null &&
        DateTime.now().difference(_openedAt!) > const Duration(seconds: 45);
    if (_seekAttempts >= 20 || timedOut) {
      debugPrint(
        '[Playback] Resume gave up at ${_position.inMilliseconds}ms '
        '(target ${target.inMilliseconds}ms)',
      );
      _pendingSeek = null;
      _seekInFlight = false;
      _finishResume(target, landed: false);
      return;
    }

    // Absolute seeks need the demuxer to know the file; wait for duration
    // before issuing a fallback seek.
    if (_duration <= Duration.zero) return;

    _seekAttempts += 1;
    _seekInFlight = true;
    debugPrint(
      '[Playback] Resume seek attempt $_seekAttempts '
      'target=${target.inMilliseconds}ms position=${_position.inMilliseconds}ms',
    );
    _service.reportSeekStarted();
    unawaited(
      _player
          .seek(target)
          .then(
            (_) {
              _seekInFlight = false;
              // Acknowledged completion before retrying: re-enter settlement
              // which either clears (within tolerance) or issues the next attempt.
              if (mounted) _settlePendingSeek();
            },
            onError: (_) {
              _seekInFlight = false;
            },
          ),
    );
  }

  /// Completes a gated resume. The player was opened paused, so playback
  /// starts here — after the position settled (or after giving up).
  void _finishResume(Duration target, {required bool landed}) {
    _resumeGateTimer?.cancel();
    final wasGated = _resumeGated;
    _resumeGated = false;
    if (wasGated && mounted) unawaited(_player.play());
    if (!mounted) return;
    if (!landed) {
      _showMessage('Could not resume — playback continues from the start.');
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Resumed from ${formatWatchTimestamp(target)}'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _persistProgress({bool forceAnchor = false}) async {
    final positionMs = _position.inMilliseconds;
    if (positionMs <= 0) return;
    // Uses captured dependencies only: this also runs from dispose(), where
    // touching `ref` throws "Using ref ... is unsafe".
    final source = _service.state.source;
    if (source == null) return;
    final durationMs = _duration.inMilliseconds;
    final key = watchKey(widget.mediaRef, widget.season, widget.episode);
    final notifier = _history;
    final existing = notifier.entryFor(key);
    final title =
        _detailsTitle ?? existing?.title ?? source.fileNameHint ?? source.name;
    final posterPath = _detailsPosterPath ?? existing?.posterPath;
    final backdropPath = _detailsBackdropPath ?? existing?.backdropPath;
    final entry = WatchEntry(
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
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: DateTime.now(),
    );
    if (entry.isFinished) {
      await notifier.remove(key);
      return;
    }
    if (entry.isTrivial) return;
    await notifier.save(entry);
    await _recordPeriodicAnchor(positionMs, force: forceAnchor);
  }

  Future<void> _setRate(double rate) => _player.setRate(rate);

  Future<void> _setVolume(double volume) => _player.setVolume(volume);

  // ── YouTube-style player controls ────────────────────────────────────────

  void _applyStoredPlaybackPreferences(AppSettings settings) {
    if (_storedPrefsApplied) return;
    _storedPrefsApplied = true;
    unawaited(_player.setVolume(settings.playerVolume));
    unawaited(_player.setRate(settings.playerRate));
  }

  void _scheduleVolumeSave(double volume) {
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final settings = ref.read(appSettingsProvider).value;
      if (settings == null) return;
      if ((settings.playerVolume - volume).abs() < 0.01) return;
      unawaited(ref.read(appSettingsProvider.notifier).setPlayerVolume(volume));
    });
  }

  void _scheduleRateSave(double rate) {
    _rateSaveTimer?.cancel();
    _rateSaveTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final settings = ref.read(appSettingsProvider).value;
      if (settings == null) return;
      if ((settings.playerRate - rate).abs() < 0.001) return;
      unawaited(ref.read(appSettingsProvider.notifier).setPlayerRate(rate));
    });
  }

  Future<void> _togglePlayPause() async {
    final wasPlaying = _player.state.playing;
    await _player.playOrPause();
    if (wasPlaying) {
      // Paused: keep fetching ahead to a deep but bounded cap so resuming
      // does not stall, without downloading the whole file.
      _service.prefetchAhead(seconds: 90);
    }
    _showHud(
      wasPlaying ? 'Paused' : 'Playing',
      icon: wasPlaying ? Icons.pause : Icons.play_arrow,
    );
  }

  Future<void> _seekBy(Duration delta, {String? label, IconData? icon}) async {
    final target = playerSeekTarget(_position, delta, _duration);
    await _player.seek(target);
    _scheduleByteObservation(target);
    if (label != null) _showHud(label, icon: icon);
  }

  Future<void> _seekTo(Duration target, {String? label, IconData? icon}) async {
    final clamped = playerSeekTarget(target, Duration.zero, _duration);
    await _player.seek(clamped);
    _scheduleByteObservation(clamped);
    if (label != null) _showHud(label, icon: icon);
  }

  /// Records where the player's own range request landed for [target].
  ///
  /// The native read head shortly after a seek is the byte offset mpv
  /// actually asked for — the exact time→byte anchor the learned map needs.
  void _scheduleByteObservation(Duration target) {
    if (target.inMilliseconds <= 0) return;
    _byteObservationTimer?.cancel();
    _byteObservationTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_recordByteObservation(target));
    });
  }

  Future<void> _recordByteObservation(Duration target) async {
    if (target.inMilliseconds <= 0) return;
    final playback = _service.state.playback;
    final source = _service.state.source;
    if (playback == null ||
        source == null ||
        playback.fromCache ||
        playback.file.size <= 0) {
      return;
    }
    final byte = _service.streamReadHead;
    if (byte == null || byte <= 0) return;
    await _cacheStore.recordTimeByteObservation(
      source,
      target.inMilliseconds,
      byte,
      fileSize: playback.file.size,
    );
  }

  DateTime? _lastPeriodicAnchorAt;

  /// Progressive map building: while playing, periodically record where the
  /// native read head sits for the current position. The read head runs a
  /// little ahead of the display position (demuxer cache), which is harmless
  /// for a prefetch hint and far better than the average-bitrate estimate on
  /// VBR files. Throttled so the cache index is not rewritten constantly.
  Future<void> _recordPeriodicAnchor(
    int positionMs, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final last = _lastPeriodicAnchorAt;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastPeriodicAnchorAt = now;
    final playback = _service.state.playback;
    final source = _service.state.source;
    if (playback == null ||
        source == null ||
        playback.fromCache ||
        playback.file.size <= 0) {
      return;
    }
    final byte = _service.streamReadHead;
    if (byte == null || byte <= 0) return;
    await _cacheStore.recordTimeByteObservation(
      source,
      positionMs,
      byte,
      fileSize: playback.file.size,
    );
  }

  Future<void> _nudgeVolume(double delta) async {
    final next = nudgedVolume(_volume, delta);
    await _setVolume(next);
    _showHud(
      'Volume ${next.round()}%',
      icon: next <= 0 ? Icons.volume_off : Icons.volume_up,
    );
  }

  Future<void> _toggleMute() async {
    final next = _volume > 0 ? 0.0 : (_lastVolume > 0 ? _lastVolume : 100.0);
    await _setVolume(next);
    _showHud(
      next <= 0 ? 'Muted' : 'Unmuted',
      icon: next <= 0 ? Icons.volume_off : Icons.volume_up,
    );
  }

  Future<void> _toggleSubtitles() async {
    final current = _player.state.track.subtitle;
    if (current.id != 'no') {
      _lastSubtitleTrack = current;
      await _selectSubtitle(SubtitleTrack.no());
      _showHud('Subtitles off', icon: Icons.subtitles_off_outlined);
      return;
    }
    final available = _realSubtitleTracks(_player.state.tracks);
    final target =
        _lastSubtitleTrack ?? (available.isEmpty ? null : available.first);
    if (target == null) {
      _showHud('No subtitles available', icon: Icons.subtitles_off_outlined);
      return;
    }
    await _selectSubtitle(target);
    _showHud('Subtitles on', icon: Icons.subtitles_outlined);
  }

  Future<void> _stepSpeed(int direction) async {
    final next = steppedPlaybackRate(_rate, direction);
    if (next == _rate) return;
    await _setRate(next);
    _showHud(formatPlaybackRate(next), icon: Icons.speed);
  }

  Future<void> _stepFrame(int direction) async {
    if (_player.state.playing) {
      _showHud('Pause to step frames', icon: Icons.info_outline);
      return;
    }
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command([
        direction < 0 ? 'frame-back-step' : 'frame-step',
      ]);
      _showHud(
        direction < 0 ? 'Frame back' : 'Frame forward',
        icon: Icons.slow_motion_video,
      );
    } catch (_) {}
  }

  Future<void> _seekToPercent(int percent) async {
    if (_duration <= Duration.zero) return;
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * percent / 100).round(),
    );
    await _player.seek(target);
    _scheduleByteObservation(target);
    _showHud('$percent%', icon: Icons.percent);
  }

  void _handleShortcut(PlayerShortcut shortcut, BuildContext context) {
    switch (shortcut.action) {
      case PlayerShortcutAction.playPause:
        unawaited(_togglePlayPause());
      case PlayerShortcutAction.seekBackward5:
        unawaited(
          _seekBy(
            const Duration(seconds: -5),
            label: '5 seconds',
            icon: Icons.replay_5,
          ),
        );
      case PlayerShortcutAction.seekForward5:
        unawaited(
          _seekBy(
            const Duration(seconds: 5),
            label: '5 seconds',
            icon: Icons.forward_5,
          ),
        );
      case PlayerShortcutAction.seekBackward10:
        unawaited(
          _seekBy(
            const Duration(seconds: -10),
            label: '10 seconds',
            icon: Icons.replay_10,
          ),
        );
      case PlayerShortcutAction.seekForward10:
        unawaited(
          _seekBy(
            const Duration(seconds: 10),
            label: '10 seconds',
            icon: Icons.forward_10,
          ),
        );
      case PlayerShortcutAction.volumeUp:
        unawaited(_nudgeVolume(5));
      case PlayerShortcutAction.volumeDown:
        unawaited(_nudgeVolume(-5));
      case PlayerShortcutAction.toggleMute:
        unawaited(_toggleMute());
      case PlayerShortcutAction.toggleFullscreen:
        unawaited(toggleFullscreen(context));
      case PlayerShortcutAction.exitFullscreen:
        if (isFullscreen(context)) unawaited(exitFullscreen(context));
      case PlayerShortcutAction.toggleSubtitles:
        unawaited(_toggleSubtitles());
      case PlayerShortcutAction.speedDown:
        unawaited(_stepSpeed(-1));
      case PlayerShortcutAction.speedUp:
        unawaited(_stepSpeed(1));
      case PlayerShortcutAction.frameStepBack:
        unawaited(_stepFrame(-1));
      case PlayerShortcutAction.frameStepForward:
        unawaited(_stepFrame(1));
      case PlayerShortcutAction.seekToPercent:
        unawaited(_seekToPercent((shortcut.value ?? 0) * 10));
      case PlayerShortcutAction.jumpToStart:
        unawaited(
          _seekTo(Duration.zero, label: 'Start', icon: Icons.skip_previous),
        );
      case PlayerShortcutAction.jumpToEnd:
        unawaited(_seekTo(_duration, label: 'End', icon: Icons.skip_next));
      case PlayerShortcutAction.showHelp:
        _showShortcutsHelp();
    }
  }

  void _showHud(String label, {IconData? icon}) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() {
      _hudLabel = label;
      _hudIcon = icon;
    });
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _hudLabel = null;
        _hudIcon = null;
      });
    });
  }

  void _showShortcutsHelp() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const _ShortcutsSheet(),
    );
  }

  Future<void> _replay() async {
    setState(() {
      _completed = false;
      _nextEpisodeSeason = null;
      _nextEpisodeNumber = null;
    });
    await _player.seek(Duration.zero);
    await _player.play();
  }

  Future<void> _resolveNextEpisode() async {
    if (widget.mediaRef.type != MediaType.tv ||
        widget.season == null ||
        widget.episode == null ||
        _resolvingNextEpisode) {
      return;
    }
    _resolvingNextEpisode = true;
    try {
      final seriesId = widget.mediaRef.id;
      final episodes = await ref.read(
        episodeListProvider((seriesId: seriesId, seasonNumber: widget.season!))
            .future,
      );
      if (!mounted) return;
      final nextInSeason = nextEpisodeNumber(
        episodes.map((episode) => episode.number),
        widget.episode!,
      );
      if (nextInSeason != null) {
        setState(() {
          _nextEpisodeSeason = widget.season;
          _nextEpisodeNumber = nextInSeason;
        });
        return;
      }
      final details = ref.read(detailsProvider(widget.mediaRef)).value;
      final nextSeason = details == null
          ? null
          : nextSeasonNumber(
              details.seasons.map((season) => season.number),
              widget.season!,
            );
      if (nextSeason == null) return;
      final nextEpisodes = await ref.read(
        episodeListProvider((seriesId: seriesId, seasonNumber: nextSeason))
            .future,
      );
      if (!mounted) return;
      final numbers =
          nextEpisodes
              .map((episode) => episode.number)
              .where((number) => number > 0)
              .toList()
            ..sort();
      if (numbers.isEmpty) return;
      setState(() {
        _nextEpisodeSeason = nextSeason;
        _nextEpisodeNumber = numbers.first;
      });
    } catch (_) {
      // End-card navigation is best effort; replay stays available.
    } finally {
      _resolvingNextEpisode = false;
    }
  }

  Future<void> _playNextEpisode() async {
    final season = _nextEpisodeSeason;
    final episode = _nextEpisodeNumber;
    if (season == null || episode == null) return;
    unawaited(_persistProgress());
    _stopOwnedSession();
    if (!mounted) return;
    context.go(
      Uri(
        path: '/sources/${widget.mediaRef.routeKey}',
        queryParameters: {'season': '$season', 'episode': '$episode'},
      ).toString(),
    );
  }

  Future<void> _selectAudio(AudioTrack track) async {
    try {
      await _player.setAudioTrack(track);
      if (track.id != 'auto' && track.id != 'no' && track.language != null) {
        final cache = ref.read(playbackCacheProvider);
        final preferences = await cache.preferences();
        await cache.savePreferences(
          preferences.copyWith(preferredAudioLanguage: track.language),
        );
      }
    } catch (_) {
      _showMessage('Could not change the audio track.');
    }
  }

  Future<void> _selectSubtitle(SubtitleTrack track) async {
    if (track.id != 'no' && track.id != 'auto') {
      _lastSubtitleTrack = track;
    }
    try {
      await _player.setSubtitleTrack(track);
      if (track.id != 'auto' && track.id != 'no' && track.language != null) {
        final cache = ref.read(playbackCacheProvider);
        final preferences = await cache.preferences();
        await cache.savePreferences(
          preferences.copyWith(preferredSubtitleLanguage: track.language),
        );
      }
    } catch (_) {
      _showMessage('Could not change subtitles.');
    }
  }

  Future<void> _applyTrackPreferences(Tracks tracks) async {
    if (_trackPreferencesApplied || !mounted) return;
    final audio = _realAudioTracks(tracks);
    final subtitles = _realSubtitleTracks(tracks);
    if (audio.isEmpty && subtitles.isEmpty) return;
    _trackPreferencesApplied = true;
    final preferences = await ref.read(playbackCacheProvider).preferences();
    final preferredAudio = preferences.preferredAudioLanguage?.toLowerCase();
    if (preferredAudio != null) {
      final track = audio
          .where((item) => item.language?.toLowerCase() == preferredAudio)
          .firstOrNull;
      if (track != null) await _selectAudio(track);
    }
    final preferredSubtitle = preferences.preferredSubtitleLanguage
        ?.toLowerCase();
    if (preferredSubtitle != null) {
      final track = subtitles
          .where((item) => item.language?.toLowerCase() == preferredSubtitle)
          .firstOrNull;
      if (track != null) await _selectSubtitle(track);
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  Future<void> _loadSubtitleFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'vtt', 'ass'],
        dialogTitle: 'Choose subtitle file',
      );
      final picked = result?.files.singleOrNull;
      if (picked?.path == null) return;
      final path = await _subtitleFiles.importFile(
        picked!.path!,
        name: picked.name,
      );
      await _selectSubtitle(
        SubtitleTrack.uri(Uri.file(path).toString(), title: picked.name),
      );
      _showMessage('Subtitle file loaded.');
    } catch (_) {
      _showMessage('Could not load that subtitle file.');
    }
  }

  Future<void> _findOnlineSubtitles() async {
    final stream = ref.read(streamingServiceProvider).state;
    final source = stream.source;
    if (source == null || _subtitleSearching) return;
    setState(() => _subtitleSearching = true);
    try {
      final urls = await ref.read(addonUrlsProvider.future);
      final choices = await ref
          .read(addonSubtitleProvider)
          .find(urls, source: source, file: stream.playback?.file);
      if (!mounted) return;
      if (choices.isEmpty) {
        _showMessage('No online subtitles were offered by your providers.');
        return;
      }
      final selected = await showModalBottomSheet<OnlineSubtitle>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Online subtitles')),
              for (final item in choices)
                ListTile(
                  title: Text(item.language),
                  subtitle: Text(item.provider),
                  onTap: () => Navigator.pop(context, item),
                ),
            ],
          ),
        ),
      );
      if (selected == null) return;
      final path = await _subtitleFiles.download(
        selected.url,
        name: '${selected.provider}_${selected.language}.srt',
      );
      await _selectSubtitle(
        SubtitleTrack.uri(
          Uri.file(path).toString(),
          title: selected.label,
          language: selected.language,
        ),
      );
      _showMessage('Subtitle loaded from ${selected.provider}.');
    } catch (_) {
      _showMessage('Could not find online subtitles right now.');
    } finally {
      if (mounted) setState(() => _subtitleSearching = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _setFit(BoxFit fit) => setState(() => _fit = fit);

  void _setAspectRatio(double? aspectRatio) =>
      setState(() => _aspectRatio = aspectRatio);

  MaterialVideoControlsThemeData _videoControlsTheme({
    required bool fullscreen,
  }) {
    final base = fullscreen
        ? kDefaultMaterialVideoControlsThemeDataFullscreen
        : kDefaultMaterialVideoControlsThemeData;
    final touchPlatform =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return base.copyWith(
      volumeGesture: true,
      seekGesture: true,
      seekOnDoubleTap: true,
      speedUpOnLongPress: touchPlatform,
      speedUpFactor: 2.0,
      primaryButtonBar: [
        const Spacer(flex: 2),
        _SeekButton(
          forward: false,
          onPressed: () => unawaited(
            _seekBy(
              const Duration(seconds: -10),
              label: '10 seconds',
              icon: Icons.replay_10,
            ),
          ),
        ),
        const Spacer(),
        const MaterialPlayOrPauseButton(iconSize: 56.0),
        const Spacer(),
        _SeekButton(
          forward: true,
          onPressed: () => unawaited(
            _seekBy(
              const Duration(seconds: 10),
              label: '10 seconds',
              icon: Icons.forward_10,
            ),
          ),
        ),
        const Spacer(flex: 2),
      ],
      topButtonBar: [
        const Spacer(),
        _InPlayerMenus(
          volume: _volume,
          fit: _fit,
          aspectRatio: _aspectRatio,
          onToggleMute: () => unawaited(_toggleMute()),
          onFitSelected: _setFit,
          onAspectRatioSelected: _setAspectRatio,
          onShowShortcuts: _showShortcutsHelp,
          onToggleStats: () => setState(() => _showStats = !_showStats),
          statsEnabled: _showStats,
        ),
      ],
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        LivePlayerTracks(
          tracks: _player.stream.tracks,
          selection: _player.stream.track,
          currentTracks: () => _player.state.tracks,
          currentSelection: () => _player.state.track,
          builder: (context, tracks, selected) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AudioTrackButton(
                tracks: tracks,
                selectedId: selected.audio.id,
                onSelected: _selectAudio,
              ),
              _SubtitleTrackButton(
                tracks: tracks,
                selectedId: selected.subtitle.id,
                onSelected: _selectSubtitle,
                onLoadLocal: _loadSubtitleFile,
                onFindOnline: _findOnlineSubtitles,
                loadingOnline: _subtitleSearching,
              ),
            ],
          ),
        ),
        _PlaybackSpeedButton(rate: _rate, onSelected: _setRate),
        const MaterialFullscreenButton(),
      ],
    );
  }

  Widget _inPlayerControls() {
    final appSettings = ref.watch(appSettingsProvider).value;
    return MaterialVideoControlsTheme(
      normal: _videoControlsTheme(fullscreen: false),
      fullscreen: _videoControlsTheme(fullscreen: true),
      child: Video(
        controller: _videoController,
        fit: _fit,
        aspectRatio: _aspectRatio,
        subtitleViewConfiguration: _subtitleViewConfiguration(appSettings),
        controls: _videoControls,
      ),
    );
  }

  SubtitleViewConfiguration _subtitleViewConfiguration(AppSettings? settings) {
    final scale = settings?.subtitleTextScale ?? 1;
    final background = switch (settings?.subtitleBackground ??
        SubtitleBackgroundStyle.translucent) {
      SubtitleBackgroundStyle.none => const Color(0x00000000),
      SubtitleBackgroundStyle.solid => const Color(0xff000000),
      SubtitleBackgroundStyle.translucent => const Color(0xaa000000),
    };
    return SubtitleViewConfiguration(
      style: TextStyle(
        height: 1.4,
        fontSize: 32 * scale,
        letterSpacing: 0,
        wordSpacing: 0,
        color: const Color(0xffffffff),
        fontWeight: FontWeight.normal,
        backgroundColor: background,
      ),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    );
  }

  /// Controls builder shared by the embedded and fullscreen [Video]s. The
  /// fullscreen route reuses this builder, so shortcuts, the HUD, and the
  /// end-of-playback card work in both modes.
  Widget _videoControls(VideoState state) {
    final episodeLabel =
        widget.mediaRef.type == MediaType.tv &&
            widget.season != null &&
            widget.episode != null
        ? 'S${widget.season} E${widget.episode}'
        : null;
    final nextEpisode = _nextEpisodeSeason == null || _nextEpisodeNumber == null
        ? null
        : 'S$_nextEpisodeSeason E$_nextEpisodeNumber';
    return PlayerShortcuts(
      onAction: _handleShortcut,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MaterialVideoControls(state),
          if (_completed)
            _EndOfPlaybackOverlay(
              episodeLabel: episodeLabel,
              nextEpisodeLabel: nextEpisode,
              onReplay: () => unawaited(_replay()),
              onNextEpisode: nextEpisode == null
                  ? null
                  : () => unawaited(_playNextEpisode()),
            ),
          IgnorePointer(
            child: _PlayerHud(label: _hudLabel, icon: _hudIcon),
          ),
          if (_showStats)
            IgnorePointer(child: _PlayerStatsOverlay(player: _player)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _bufferSubscription?.cancel();
    _tracksSubscription?.cancel();
    _rateSubscription?.cancel();
    _volumeSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _saveTimer?.cancel();
    _byteObservationTimer?.cancel();
    _hudTimer?.cancel();
    _volumeSaveTimer?.cancel();
    _rateSaveTimer?.cancel();
    _resumeGateTimer?.cancel();
    // Force a final anchor at the exit position: it is the most likely
    // resume target and may be newer than the throttled periodic anchor.
    unawaited(_persistProgress(forceAnchor: true));
    _stopOwnedSession();
    // The player is app-lifetime (see mediaKitPlayerProvider): disposing it
    // here races media_kit's libmpv wakeup callback and crashes debug builds.
    // Stopping playback is enough; the next screen reuses the instance.
    unawaited(_player.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(streamingStateProvider, (_, next) {
      next.whenData(_openIfNeeded);
    });
    // Separate subscriptions: phase/controls rebuild on state changes while
    // the statistics strip below listens to the focused stats provider.
    // Polling itself slows during steady playback (see _updatePolling).
    final streamState = ref.watch(streamingStateProvider);
    final state = streamState.value ?? ref.read(streamingServiceProvider).state;
    final details = ref.watch(detailsProvider(widget.mediaRef));
    final detailsValue = details.value;
    if (detailsValue != null) {
      _detailsTitle = detailsValue.item.title;
      _detailsPosterPath = detailsValue.item.posterPath;
      _detailsBackdropPath = detailsValue.item.backdropPath;
    }
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

    return PopScope(
      onPopInvokedWithResult: (_, _) {
        unawaited(_persistProgress());
        _stopOwnedSession();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            episodeLabel == null ? mediaTitle : '$mediaTitle · $episodeLabel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [_StreamStatusMenu(state: state)],
        ),
        body: state.phase == StreamingPhase.unsupported
            ? _Unsupported(message: state.message)
            : ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Wide windows: put the details in a right sidebar and
                    // let the video use the full height, instead of leaving
                    // the letterbox side space empty.
                    final wide = constraints.maxWidth >= 1100;
                    final stage = _VideoStage(
                      aspectRatio: _aspectRatio ?? 16 / 9,
                      maxHeight: wide ? constraints.maxHeight : null,
                      alignTop: wide,
                      child: state.playback == null
                          ? _LoadingState(
                              state: state,
                              onCancel: () {
                                _stopOwnedSession();
                                if (context.mounted) context.pop();
                              },
                            )
                          : _inPlayerControls(),
                    );
                    final details = _buildDetails(
                      state,
                      episodeLabel,
                      mediaTitle,
                    );
                    if (!wide) {
                      return ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          stage,
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: DesignTokens.contentMaxWidth,
                              ),
                              child: details,
                            ),
                          ),
                        ],
                      );
                    }
                    final sidebarWidth = (constraints.maxWidth * 0.22)
                        .clamp(320.0, 420.0)
                        .toDouble();
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: stage),
                        Container(
                          width: sidebarWidth,
                          decoration: const BoxDecoration(
                            border: Border(
                              left: BorderSide(color: DesignTokens.line),
                            ),
                          ),
                          child: SingleChildScrollView(child: details),
                        ),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// Details and transfer statistics. Rendered under the video on narrow
  /// windows and in the right sidebar on wide ones.
  Widget _buildDetails(
    StreamingState state,
    String? episodeLabel,
    String mediaTitle,
  ) {
    return Padding(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.phase == StreamingPhase.error)
            _ErrorState(
              message: state.message,
              onRetry: _retry,
              onBack: () => context.pop(),
              onSwitchSource: () {
                unawaited(_persistProgress());
                _stopOwnedSession();
                context.go(
                  Uri(
                    path: '/sources/${widget.mediaRef.routeKey}',
                    queryParameters: {
                      if (widget.season != null) 'season': '${widget.season}',
                      if (widget.episode != null)
                        'episode': '${widget.episode}',
                    },
                  ).toString(),
                );
              },
            )
          else ...[
            if (episodeLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: DesignTokens.space2),
                child: Badge(label: episodeLabel, tone: BadgeTone.neutral),
              ),
            Text(
              state.playback?.file.name ?? mediaTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              state.origin == PlaybackOrigin.cache
                  ? 'Playing from this device. This replay starts without a provider lookup.'
                  : 'Seeking works while downloading. Playback resumes from the local stream once enough data arrives.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: DesignTokens.textSecondary),
            ),
            if (state.stats.totalBytes > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${formatBytes(state.stats.downloadedBytes)} of ${formatBytes(state.stats.totalBytes)} · ${formatSpeed(state.stats.downloadRate)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textTertiary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(height: DesignTokens.space4),
            TorrentStatistics(stats: state.stats),
            const SizedBox(height: DesignTokens.space2),
            _DiagnosticsStrip(state: state),
          ],
        ],
      ),
    );
  }

  void _stopOwnedSession() {
    final token = _sessionToken;
    _sessionToken = null;
    if (token != null) {
      token.cancel();
      // Only stop the service if it still owns our session; rapid source
      // switches bump the generation and must not kill the new session.
      if (_service.state.sessionId == token.id) {
        unawaited(_service.stop());
      } else {
        _service.cancelSession(token.id);
      }
    }
  }
}

/// Full-bleed black stage that caps the video height to the viewport so
/// the in-player bottom control bar always stays visible without scrolling.
class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.aspectRatio,
    required this.child,
    this.maxHeight,
    this.alignTop = false,
  });
  final double aspectRatio;
  final Widget child;

  /// Caps the stage height. When null, 62% of the viewport keeps the
  /// in-player controls and the details below both visible.
  final double? maxHeight;

  /// Pins the video to the top of the stage instead of centering it, so a
  /// full-height stage does not waste a black band above the picture.
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    final cap = maxHeight ?? MediaQuery.sizeOf(context).height * 0.62;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        var height = maxWidth / aspectRatio;
        if (height > cap) height = cap;
        if (height <= 0) height = maxWidth / aspectRatio;
        final width = height * aspectRatio;
        return Container(
          color: Colors.black,
          width: maxWidth,
          height: height,
          alignment: alignTop ? Alignment.topCenter : Alignment.center,
          child: SizedBox(width: width, height: height, child: child),
        );
      },
    );
  }
}

/// Stream status embedded in the top bar. Tapping it opens a small dropdown
/// with the current phase and transfer details.
class _StreamStatusMenu extends StatelessWidget {
  const _StreamStatusMenu({required this.state});
  final StreamingState state;

  @override
  Widget build(BuildContext context) {
    final label = formatPhase(state.phase.name);
    final dot = switch (state.phase) {
      StreamingPhase.error => DesignTokens.danger,
      StreamingPhase.playing || StreamingPhase.ready => DesignTokens.accent,
      _ => DesignTokens.warn,
    };
    final hasStats =
        state.stats.totalBytes > 0 || state.stats.downloadedBytes > 0;
    return PopupMenuButton<void>(
      tooltip: 'Stream status: $label',
      offset: const Offset(0, 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: dot),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: dot),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                if (state.message != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    state.message!,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: DesignTokens.textSecondary),
                  ),
                ],
                const SizedBox(height: 8),
                if (hasStats)
                  TorrentStatistics(stats: state.stats)
                else
                  Text(
                    'Transfer details appear once downloading starts.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: DesignTokens.textSecondary),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.state, required this.onCancel});
  final StreamingState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = state.stats;
    final determinate = stats.totalBytes > 0 && stats.progress > 0;
    final bufferPct = stats.bufferProgress;
    final hasLiveStats =
        stats.downloadRate > 0 ||
        (stats.peers ?? 0) > 0 ||
        stats.downloadedBytes > 0;
    final elapsed = state.startedAt == null
        ? null
        : DateTime.now().difference(state.startedAt!);
    final elapsedLabel = elapsed == null ? null : '${elapsed.inSeconds}s';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (determinate)
              SizedBox(
                width: 220,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: stats.progress.clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(stats.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}% · ${formatBytes(stats.downloadedBytes)} of ${formatBytes(stats.totalBytes)}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: DesignTokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (bufferPct > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Buffer ${(bufferPct.clamp(0.0, 100.0)).toStringAsFixed(0)}% ready',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: DesignTokens.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              )
            else if (bufferPct > 0)
              SizedBox(
                width: 220,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: (bufferPct / 100).clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Buffer ${bufferPct.toStringAsFixed(0)}% ready',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: DesignTokens.textSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              )
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(switch ((state.phase, state.detail)) {
              (StreamingPhase.resolving, StreamingDetail.findingSources) =>
                'Finding sources${elapsedLabel == null ? '' : ' ($elapsedLabel)'}',
              (StreamingPhase.resolving, _) =>
                elapsed != null && elapsed.inSeconds > 10
                    ? 'Connecting to peers ($elapsedLabel elapsed)'
                    : 'Connecting to the source',
              (StreamingPhase.buffering, _) =>
                state.isBuffering
                    ? 'Buffering the video'
                    : 'Buffering the video',
              (StreamingPhase.seeking, _) => 'Loading the new position',
              (_, StreamingDetail.reconnecting) => 'Reconnecting',
              _ => 'Preparing the local stream',
            }, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              state.phase == StreamingPhase.resolving
                  ? 'The first playback may need torrent information.'
                  : hasLiveStats
                  ? '${formatSpeed(stats.downloadRate)} · ${stats.peers ?? 0} peers${elapsedLabel == null ? '' : ' · $elapsedLabel'}'
                  : 'Playback begins as soon as enough video is ready.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (state.message != null) ...[
              const SizedBox(height: 8),
              Text(
                state.message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: DesignTokens.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DisplayOption {
  fit,
  fill,
  stretch,
  original,
  fourThree,
  sixteenNine,
  cinema,
}

String _controlsTrackLabel(String id, String? title, String? language) {
  if (id == 'no') return 'Off';
  if (id == 'auto') return 'Auto';
  final values = [
    if (language != null && language.isNotEmpty) language,
    if (title != null && title.isNotEmpty) title,
  ];
  return values.isEmpty ? 'Track $id' : values.join(' · ');
}

List<AudioTrack> _realAudioTracks(Tracks tracks) => tracks.audio
    .where((track) => track.id != 'auto' && track.id != 'no')
    .toList();

List<SubtitleTrack> _realSubtitleTracks(Tracks tracks) => tracks.subtitle
    .where((track) => track.id != 'auto' && track.id != 'no')
    .toList();

String _trackDetails(dynamic track) {
  final details = <String>[
    if (track.codec is String && track.codec.isNotEmpty) track.codec as String,
    if (track.channels is String && track.channels.isNotEmpty)
      track.channels as String,
  ];
  return details.join(' · ');
}

class _AudioTrackButton extends StatelessWidget {
  const _AudioTrackButton({
    required this.tracks,
    required this.selectedId,
    required this.onSelected,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(AudioTrack) onSelected;

  @override
  Widget build(BuildContext context) {
    final available = _realAudioTracks(tracks);
    return PopupMenuButton<AudioTrack>(
      tooltip: available.isEmpty ? 'No embedded audio tracks' : 'Audio track',
      onSelected: (track) => onSelected(track),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: AudioTrack.auto(),
          child: _TrackMenuRow(label: 'Auto', selected: selectedId == 'auto'),
        ),
        if (available.isEmpty)
          const PopupMenuItem(
            enabled: false,
            child: Text('No embedded audio tracks'),
          ),
        for (final track in available)
          PopupMenuItem(
            value: track,
            child: _TrackMenuRow(
              label: _controlsTrackLabel(track.id, track.title, track.language),
              detail: _trackDetails(track),
              selected: selectedId == track.id,
            ),
          ),
      ],
      icon: const Icon(Icons.multitrack_audio),
    );
  }
}

class _SubtitleTrackButton extends StatelessWidget {
  const _SubtitleTrackButton({
    required this.tracks,
    required this.selectedId,
    required this.onSelected,
    required this.onLoadLocal,
    required this.onFindOnline,
    required this.loadingOnline,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(SubtitleTrack) onSelected;
  final Future<void> Function() onLoadLocal;
  final Future<void> Function() onFindOnline;
  final bool loadingOnline;

  @override
  Widget build(BuildContext context) {
    final available = _realSubtitleTracks(tracks);
    return PopupMenuButton<_SubtitleSelection>(
      tooltip: available.isEmpty ? 'Subtitles' : 'Subtitle track',
      onSelected: (selection) async {
        switch (selection.action) {
          case _SubtitleAction.off:
            await onSelected(SubtitleTrack.no());
          case _SubtitleAction.auto:
            if (available.isNotEmpty) await onSelected(available.first);
          case _SubtitleAction.track:
            await onSelected(selection.track!);
          case _SubtitleAction.local:
            await onLoadLocal();
          case _SubtitleAction.online:
            await onFindOnline();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: const _SubtitleSelection.off(),
          child: _TrackMenuRow(label: 'Off', selected: selectedId == 'no'),
        ),
        PopupMenuItem(
          value: const _SubtitleSelection.auto(),
          enabled: available.isNotEmpty,
          child: _TrackMenuRow(
            label: 'On',
            selected: selectedId != 'no' && available.isNotEmpty,
          ),
        ),
        if (available.isEmpty)
          const PopupMenuItem(
            enabled: false,
            child: Text('No embedded subtitles'),
          ),
        for (final track in available)
          PopupMenuItem(
            value: _SubtitleSelection.track(track),
            child: _TrackMenuRow(
              label: _controlsTrackLabel(track.id, track.title, track.language),
              detail: _trackDetails(track),
              selected: selectedId == track.id,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _SubtitleSelection.local(),
          child: Text('Load subtitle file'),
        ),
        PopupMenuItem(
          value: const _SubtitleSelection.online(),
          enabled: !loadingOnline,
          child: Text(loadingOnline ? 'Finding subtitles…' : 'Find online'),
        ),
      ],
      icon: Icon(
        selectedId == 'no'
            ? Icons.subtitles_off_outlined
            : Icons.subtitles_outlined,
      ),
    );
  }
}

class _TrackMenuRow extends StatelessWidget {
  const _TrackMenuRow({
    required this.label,
    this.detail = '',
    this.selected = false,
  });
  final String label;
  final String detail;
  final bool selected;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            if (detail.isNotEmpty)
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      if (selected) const Icon(Icons.check, size: 16),
    ],
  );
}

enum _SubtitleAction { off, auto, track, local, online }

class _SubtitleSelection {
  const _SubtitleSelection.off() : action = _SubtitleAction.off, track = null;
  const _SubtitleSelection.auto() : action = _SubtitleAction.auto, track = null;
  const _SubtitleSelection.local()
    : action = _SubtitleAction.local,
      track = null;
  const _SubtitleSelection.online()
    : action = _SubtitleAction.online,
      track = null;
  const _SubtitleSelection.track(this.track) : action = _SubtitleAction.track;

  final _SubtitleAction action;
  final SubtitleTrack? track;
}

class _PlaybackSpeedButton extends StatelessWidget {
  const _PlaybackSpeedButton({required this.rate, required this.onSelected});

  final double rate;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Playback speed (${formatPlaybackRate(rate)})',
      onSelected: onSelected,
      itemBuilder: (context) => playerPlaybackRates
          .map(
            (value) => PopupMenuItem(
              value: value,
              child: Row(
                children: [
                  Expanded(child: Text(formatPlaybackRate(value))),
                  if (value == rate) const Icon(Icons.check, size: 16),
                ],
              ),
            ),
          )
          .toList(),
      icon: const Icon(Icons.speed),
    );
  }
}

/// YouTube-style skip button used in the center controls bar.
class _SeekButton extends StatelessWidget {
  const _SeekButton({required this.forward, required this.onPressed});

  final bool forward;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: forward ? 'Forward 10 seconds' : 'Back 10 seconds',
      onPressed: onPressed,
      color: Colors.white,
      iconSize: 36,
      icon: Icon(forward ? Icons.forward_10 : Icons.replay_10),
    );
  }
}

class _InPlayerMenus extends StatelessWidget {
  const _InPlayerMenus({
    required this.volume,
    required this.fit,
    required this.aspectRatio,
    required this.onToggleMute,
    required this.onFitSelected,
    required this.onAspectRatioSelected,
    required this.onShowShortcuts,
    required this.onToggleStats,
    required this.statsEnabled,
  });

  final double volume;
  final BoxFit fit;
  final double? aspectRatio;
  final VoidCallback onToggleMute;
  final ValueChanged<BoxFit> onFitSelected;
  final ValueChanged<double?> onAspectRatioSelected;
  final VoidCallback onShowShortcuts;
  final VoidCallback onToggleStats;
  final bool statsEnabled;

  void _selectDisplay(_DisplayOption option) {
    switch (option) {
      case _DisplayOption.fit:
        onFitSelected(BoxFit.contain);
      case _DisplayOption.fill:
        onFitSelected(BoxFit.cover);
      case _DisplayOption.stretch:
        onFitSelected(BoxFit.fill);
      case _DisplayOption.original:
        onAspectRatioSelected(null);
      case _DisplayOption.fourThree:
        onAspectRatioSelected(4 / 3);
      case _DisplayOption.sixteenNine:
        onAspectRatioSelected(16 / 9);
      case _DisplayOption.cinema:
        onAspectRatioSelected(21 / 9);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Video display',
          child: PopupMenuButton<_DisplayOption>(
            icon: const Icon(Icons.aspect_ratio, color: Colors.white),
            onSelected: _selectDisplay,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _DisplayOption.fit,
                child: Text('Fit video'),
              ),
              PopupMenuItem(
                value: _DisplayOption.fill,
                child: Text('Fill screen'),
              ),
              PopupMenuItem(
                value: _DisplayOption.stretch,
                child: Text('Stretch video'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _DisplayOption.original,
                child: Text('Original ratio'),
              ),
              PopupMenuItem(
                value: _DisplayOption.fourThree,
                child: Text('4:3 ratio'),
              ),
              PopupMenuItem(
                value: _DisplayOption.sixteenNine,
                child: Text('16:9 ratio'),
              ),
              PopupMenuItem(
                value: _DisplayOption.cinema,
                child: Text('21:9 ratio'),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: volume <= 0 ? 'Unmute' : 'Mute',
          color: Colors.white,
          onPressed: onToggleMute,
          icon: Icon(volume <= 0 ? Icons.volume_off : Icons.volume_up),
        ),
        IconButton(
          tooltip: 'Keyboard shortcuts',
          color: Colors.white,
          onPressed: onShowShortcuts,
          icon: const Icon(Icons.keyboard_outlined),
        ),
        IconButton(
          tooltip: statsEnabled ? 'Hide playback stats' : 'Playback stats',
          color: statsEnabled ? DesignTokens.accent : Colors.white,
          onPressed: onToggleStats,
          icon: const Icon(Icons.monitor_heart_outlined),
        ),
      ],
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({this.message});
  final String? message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppEmpty(
        icon: Icons.web_asset_off_outlined,
        title: 'Playback is not available on web',
        hint: message ?? 'Torrent streaming needs the desktop or mobile app. Browse the catalogue here, then play on a supported device.',
        action: FilledButton.icon(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.home_outlined),
          label: const Text('Browse catalogue'),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    required this.onBack,
    this.onSwitchSource,
  });
  final String? message;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback? onSwitchSource;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius: BorderRadius.circular(DesignTokens.radiusCard),
        border: Border.all(color: DesignTokens.danger.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.all(DesignTokens.space4),
      child: Column(
        children: [
          const Icon(Icons.error_outline, size: 40, color: DesignTokens.danger),
          const SizedBox(height: DesignTokens.space3),
          Text(
            'Playback failed',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: DesignTokens.space2),
          Text(
            message ?? 'Streaming failed. Try another source.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: DesignTokens.textSecondary,
            ),
          ),
          const SizedBox(height: DesignTokens.space4),
          Wrap(
            spacing: DesignTokens.space2,
            runSpacing: DesignTokens.space2,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Go back'),
              ),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              if (onSwitchSource != null)
                OutlinedButton.icon(
                  onPressed: onSwitchSource,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Switch source'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsStrip extends ConsumerWidget {
  const _DiagnosticsStrip({required this.state});
  final StreamingState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diag = state.diagnostics;
    final bridge = ref.watch(bridgeVersionProvider);
    final tapMs = diag?['tapToFirstFrameMs'];
    final buffering = diag?['bufferingEvents'];
    final stalls = diag?['stallEvents'];
    final seeks = diag?['seekEvents'];
    final parts = <String>[
      'native $bridge',
      if (tapMs != null) 'first frame ${tapMs}ms',
      if (buffering != null) 'buffering x$buffering',
      if (stalls != null && (stalls as int) > 0) 'stalls x$stalls',
      if (seeks != null && (seeks as int) > 0) 'seeks x$seeks',
      if (state.bufferedPositionMs != null)
        'buffered ${Duration(milliseconds: state.bufferedPositionMs!).inSeconds}s',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: DesignTokens.textTertiary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Modal sheet listing every shortcut in [playerShortcuts] that opts into help.
class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    final entries = playerShortcuts
        .where((shortcut) => shortcut.helpKeys != null)
        .toList(growable: false);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(
              'Keyboard shortcuts',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          for (final shortcut in entries)
            ListTile(
              dense: true,
              title: Text(shortcut.helpDescription ?? ''),
              trailing: _KeyChip(label: shortcut.helpKeys!),
            ),
          const ListTile(
            dense: true,
            title: Text('Back or forward 10 seconds'),
            trailing: _KeyChip(label: 'Double-tap'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: DesignTokens.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: DesignTokens.lineStrong),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    );
  }
}

/// Transient feedback for keyboard/button actions (seek, volume, speed).
class _PlayerHud extends StatelessWidget {
  const _PlayerHud({this.label, this.icon});

  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: label == null ? 0 : 1,
      duration: const Duration(milliseconds: 150),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
              ],
              if (label != null)
                Text(
                  label!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// End-of-playback card: replay plus next episode for series.
class _EndOfPlaybackOverlay extends StatelessWidget {
  const _EndOfPlaybackOverlay({
    required this.episodeLabel,
    required this.nextEpisodeLabel,
    required this.onReplay,
    this.onNextEpisode,
  });

  final String? episodeLabel;
  final String? nextEpisodeLabel;
  final VoidCallback onReplay;
  final VoidCallback? onNextEpisode;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 40),
          const SizedBox(height: 12),
          Text(
            episodeLabel == null
                ? 'Playback finished'
                : '$episodeLabel finished',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onReplay,
                icon: const Icon(Icons.replay),
                label: const Text('Replay'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
              ),
              if (onNextEpisode != null)
                FilledButton.icon(
                  onPressed: onNextEpisode,
                  icon: const Icon(Icons.skip_next),
                  label: Text(
                    nextEpisodeLabel == null
                        ? 'Next episode'
                        : 'Next: $nextEpisodeLabel',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Stats-for-nerds style overlay; refreshes once per second while visible.
class _PlayerStatsOverlay extends ConsumerStatefulWidget {
  const _PlayerStatsOverlay({required this.player});

  final Player player;

  @override
  ConsumerState<_PlayerStatsOverlay> createState() =>
      _PlayerStatsOverlayState();
}

class _PlayerStatsOverlayState extends ConsumerState<_PlayerStatsOverlay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final streaming =
        ref.watch(streamingStateProvider).value ??
        ref.read(streamingServiceProvider).state;
    final bridge = ref.watch(bridgeVersionProvider);
    final player = widget.player;
    final diag = streaming.diagnostics;
    final video = player.state.videoParams;
    final audio = player.state.audioParams;
    final lines = <String>[
      'phase ${streaming.phase.name}',
      'native $bridge',
      if (diag?['tapToFirstFrameMs'] != null)
        'first frame ${diag!['tapToFirstFrameMs']}ms',
      if (diag?['bufferingEvents'] != null)
        'buffering x${diag!['bufferingEvents']}',
      if (diag?['stallEvents'] != null) 'stalls x${diag!['stallEvents']}',
      if (diag?['seekEvents'] != null) 'seeks x${diag!['seekEvents']}',
      'position ${_clock(player.state.position)} / '
          '${_clock(player.state.duration)}',
      'buffer ${player.state.buffer.inSeconds}s',
      if (video.w != null && video.h != null)
        'video ${video.w}x${video.h}'
            '${video.pixelformat == null ? '' : ' ${video.pixelformat}'}',
      if (audio.format != null || audio.sampleRate != null)
        'audio ${[if (audio.format != null) audio.format, if (audio.sampleRate != null) '${audio.sampleRate}Hz'].join(' ')}',
      'rate ${player.state.rate}x · volume ${player.state.volume.round()}%',
    ];
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          lines.join('\n'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
