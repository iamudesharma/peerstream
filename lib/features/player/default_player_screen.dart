import 'dart:async';

import 'package:file_picker/file_picker.dart';
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
import '../../services/streaming/playback_config.dart';
import '../../services/streaming/playback_session.dart';
import '../../services/streaming/source_ranking.dart';
import '../../services/streaming/streaming_service.dart';
import '../../services/subtitles/subtitle_provider.dart';
import '../../services/subtitles/subtitle_store.dart';
import '../../services/torrent/native_torrent_engine.dart';
import '../statistics/torrent_statistics.dart';
import 'live_player_tracks.dart';

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
  Duration? _pendingSeek;
  int _seekAttempts = 0;
  bool _seekInFlight = false;
  DateTime? _openedAt;
  final SubtitleFileStore _subtitleFiles = SubtitleFileStore();
  bool _trackPreferencesApplied = false;
  bool _subtitleSearching = false;
  bool _askedAboutResume = false;
  PlaybackSessionToken? _sessionToken;

  @override
  void initState() {
    super.initState();
    _service = ref.read(streamingServiceProvider);
    _player = Player();
    _errorSubscription = _player.stream.error.listen((error) {
      if (mounted) {
        _service.reportError('Playback failed. Try another source or retry.');
      }
    });
    _videoController = VideoController(_player);
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
    });
    _volumeSubscription = _player.stream.volume.listen((volume) {
      if (mounted) setState(() => _volume = volume);
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
      _openedUri = null;
      _pendingSeek = preservePosition ?? _positionOrExplicit();
      _seekAttempts = 0;
      _seekInFlight = false;
      _openedAt = null;
      _trackPreferencesApplied = false;
      _askedAboutResume = false;
      await _player.stop();
      if (!mounted) {
        return;
      }
      final tokenAtEntry = _sessionToken;
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
      if (!mounted || _sessionToken != tokenAtEntry) return;
      final cachedSource = cached?.source;
      if (cachedSource != null) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (!mounted || _sessionToken != tokenAtEntry) return;
        if (policy.allows(cachedSource)) {
          if (!mounted) return;
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
      await _service.start(source, claimed: token);
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
    _openedAt = DateTime.now();
    // Open immediately with the explicit resume (if any) so TTFB is not
    // blocked on the "Continue watching?" dialog. History resume is handled
    // via seek after open.
    final explicitStart = _explicitStart() ?? _pendingSeek;
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
        Media(uri, httpHeaders: state.source?.headers, start: explicitStart),
        play: true,
      );
      if (explicitStart != null) {
        _pendingSeek = explicitStart;
        _seekAttempts = 0;
        _seekInFlight = false;
        _settlePendingSeek();
      }
      // History-based resume (no explicit `resume` param): ask after open so
      // the dialog think-time never delays first frame.
      unawaited(_maybeHistoryResume());
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
    if (resume == true && mounted) {
      _pendingSeek = target;
      _seekAttempts = 0;
      _settlePendingSeek();
    }
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
    if (_seekAttempts >= 20) {
      _pendingSeek = null;
      _seekInFlight = false;
      return;
    }
    final openedAt = _openedAt;
    if (openedAt != null &&
        DateTime.now().difference(openedAt) > const Duration(seconds: 45)) {
      _pendingSeek = null;
      _seekInFlight = false;
      return;
    }
    if (_duration <= Duration.zero) return;
    if (_position + const Duration(seconds: 3) >= target &&
        _position <= target + const Duration(seconds: 30)) {
      _pendingSeek = null;
      _seekInFlight = false;
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Resumed from ${formatWatchTimestamp(target)}'),
              duration: const Duration(seconds: 2),
            ),
          );
      }
      _service.reportSeekSettled();
      return;
    }
    _seekAttempts += 1;
    _seekInFlight = true;
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

  Future<void> _persistProgress() async {
    final positionMs = _position.inMilliseconds;
    if (positionMs <= 0) return;
    final state = ref.read(streamingServiceProvider).state;
    final source = state.source;
    if (source == null) return;
    final durationMs = _duration.inMilliseconds;
    final key = watchKey(widget.mediaRef, widget.season, widget.episode);
    final notifier = ref.read(watchHistoryProvider.notifier);
    final existing = ref.read(watchHistoryProvider).value?.where((entry) {
      return entry.key == key;
    }).firstOrNull;
    String title = existing?.title ?? source.fileNameHint ?? source.name;
    String? posterPath = existing?.posterPath;
    String? backdropPath = existing?.backdropPath;
    final details = ref.read(detailsProvider(widget.mediaRef)).value;
    if (details != null) {
      title = details.item.title;
      posterPath = details.item.posterPath;
      backdropPath = details.item.backdropPath;
    }
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
  }

  Future<void> _setRate(double rate) => _player.setRate(rate);

  Future<void> _setVolume(double volume) => _player.setVolume(volume);

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
    return base.copyWith(
      volumeGesture: true,
      seekGesture: true,
      seekOnDoubleTap: true,
      topButtonBar: [
        const Spacer(),
        _InPlayerMenus(
          volume: _volume,
          fit: _fit,
          aspectRatio: _aspectRatio,
          onVolumeChanged: _setVolume,
          onFitSelected: _setFit,
          onAspectRatioSelected: _setAspectRatio,
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
    return MaterialVideoControlsTheme(
      normal: _videoControlsTheme(fullscreen: false),
      fullscreen: _videoControlsTheme(fullscreen: true),
      child: Video(
        controller: _videoController,
        fit: _fit,
        aspectRatio: _aspectRatio,
        controls: MaterialVideoControls,
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
    _saveTimer?.cancel();
    unawaited(_persistProgress());
    _stopOwnedSession();
    unawaited(_player.dispose());
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
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _VideoStage(
                      aspectRatio: _aspectRatio ?? 16 / 9,
                      child: state.playback == null
                          ? _LoadingState(
                              state: state,
                              onCancel: () {
                                _stopOwnedSession();
                                if (context.mounted) context.pop();
                              },
                            )
                          : _inPlayerControls(),
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: DesignTokens.contentMaxWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(
                            DesignTokens.pageGutter,
                          ),
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
                                        path:
                                            '/sources/${widget.mediaRef.routeKey}',
                                        queryParameters: {
                                          if (widget.season != null)
                                            'season': '${widget.season}',
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
                                    padding: const EdgeInsets.only(
                                      bottom: DesignTokens.space2,
                                    ),
                                    child: Badge(
                                      label: episodeLabel,
                                      tone: BadgeTone.neutral,
                                    ),
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
                                      ?.copyWith(
                                        color: DesignTokens.textSecondary,
                                      ),
                                ),
                                if (state.stats.totalBytes > 0) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    '${formatBytes(state.stats.downloadedBytes)} of ${formatBytes(state.stats.totalBytes)} · ${formatSpeed(state.stats.downloadRate)}',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: DesignTokens.textTertiary,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
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
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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
  const _VideoStage({required this.aspectRatio, required this.child});
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.62;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        var height = maxWidth / aspectRatio;
        if (height > maxHeight) height = maxHeight;
        if (height <= 0) height = maxWidth / aspectRatio;
        final width = height * aspectRatio;
        return Container(
          color: Colors.black,
          width: maxWidth,
          height: height,
          alignment: Alignment.center,
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
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    return PopupMenuButton<double>(
      tooltip: 'Playback speed (${rate.toStringAsFixed(rate == 1 ? 0 : 2)}x)',
      onSelected: onSelected,
      itemBuilder: (context) => rates
          .map(
            (value) => PopupMenuItem(
              value: value,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${value.toStringAsFixed(value == 1 ? 0 : 2)}x',
                    ),
                  ),
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

class _InPlayerMenus extends StatelessWidget {
  const _InPlayerMenus({
    required this.volume,
    required this.fit,
    required this.aspectRatio,
    required this.onVolumeChanged,
    required this.onFitSelected,
    required this.onAspectRatioSelected,
  });

  final double volume;
  final BoxFit fit;
  final double? aspectRatio;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<BoxFit> onFitSelected;
  final ValueChanged<double?> onAspectRatioSelected;

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
          onPressed: () => onVolumeChanged(volume <= 0 ? 100 : 0),
          icon: Icon(volume <= 0 ? Icons.volume_off : Icons.volume_up),
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
