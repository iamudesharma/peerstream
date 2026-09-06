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
import '../../models/watch_progress.dart';
import '../../providers/app_providers.dart';
import '../../services/streaming/streaming_service.dart';
import '../../services/subtitles/subtitle_provider.dart';
import '../../services/subtitles/subtitle_store.dart';
import '../statistics/torrent_statistics.dart';
import 'live_player_tracks.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    required this.mediaRef,
    required this.sourceId,
    this.season,
    this.episode,
    this.resumeMs,
    super.key,
  });
  final MediaRef mediaRef;
  final String sourceId;
  final int? season;
  final int? episode;
  final int? resumeMs;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<bool>? _playingSubscription;
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
  Timer? _saveTimer;
  Duration? _pendingSeek;
  int _seekAttempts = 0;
  DateTime? _openedAt;
  final SubtitleFileStore _subtitleFiles = SubtitleFileStore();
  bool _trackPreferencesApplied = false;
  bool _subtitleSearching = false;
  bool _askedAboutResume = false;
  int? _ownedSessionId;

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
      if (position > Duration.zero && mounted) {
        _service.markPlaying();
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

  Future<void> _start() async {
    try {
      _openedUri = null;
      _pendingSeek = null;
      _seekAttempts = 0;
      _openedAt = null;
      _trackPreferencesApplied = false;
      _askedAboutResume = false;
      await _player.stop();
      if (!mounted) {
        return;
      }
      final cached = await ref
          .read(playbackCacheProvider)
          .lookupRequest(
            widget.mediaRef,
            widget.season,
            widget.episode,
            widget.sourceId,
          );
      final cachedSource = cached?.source;
      if (cachedSource != null) {
        final policy = await ref.read(sourcePolicyProvider.future);
        if (policy.allows(cachedSource)) {
          if (!mounted) return;
          _ownedSessionId = await _service.start(cachedSource);
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
      if (!mounted) {
        return;
      }
      final source = results
          .expand((r) => r.sources)
          .where((s) => s.id == widget.sourceId)
          .firstOrNull;
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
      if (!mounted) return;
      _ownedSessionId = await _service.start(source);
    } catch (_) {
      if (mounted) {
        _service.reportError(
          'Unable to open this source. Go back and search again.',
        );
      }
    }
  }

  Future<void> _retry() async {
    _pendingSeek = null;
    _seekAttempts = 0;
    _ownedSessionId = null;
    ref.invalidate(
      sourceResultsProvider((
        media: widget.mediaRef,
        season: widget.season,
        episode: widget.episode,
      )),
    );
    await _start();
  }

  Future<void> _openIfNeeded(StreamingState state) async {
    final uri = state.playback?.uri.toString();
    if (!mounted ||
        uri == null ||
        uri == _openedUri ||
        state.phase == StreamingPhase.error) {
      return;
    }
    _openedUri = uri;
    _trackPreferencesApplied = false;
    _openedAt = DateTime.now();
    final resumeTarget = await _chooseResumeTarget();
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        // The local torrent HTTP response may wait for a missing piece.
        // mpv's default five-second timeout is too short on slow connections.
        await native.setProperty('network-timeout', '300');
      }
      await _player.open(
        Media(uri, httpHeaders: state.source?.headers, start: resumeTarget),
        play: true,
      );
      if (resumeTarget != null) {
        _pendingSeek = resumeTarget;
        _seekAttempts = 0;
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

  Future<Duration?> _chooseResumeTarget() async {
    final target = _resumeTarget();
    if (target == null || _askedAboutResume || !mounted) return target;
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

  void _settlePendingSeek() {
    final target = _pendingSeek;
    if (target == null || !mounted) return;
    if (_seekAttempts >= 20) {
      _pendingSeek = null;
      return;
    }
    final openedAt = _openedAt;
    if (openedAt != null &&
        DateTime.now().difference(openedAt) > const Duration(seconds: 45)) {
      _pendingSeek = null;
      return;
    }
    if (_duration <= Duration.zero) return;
    if (_position + const Duration(seconds: 3) >= target &&
        _position <= target + const Duration(seconds: 30)) {
      _pendingSeek = null;
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
      return;
    }
    _seekAttempts += 1;
    unawaited(_player.seek(target));
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
        ),
        body: state.phase == StreamingPhase.unsupported
            ? _Unsupported(message: state.message)
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: DesignTokens.contentMaxWidth,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(DesignTokens.pageGutter),
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            DesignTokens.radiusCard,
                          ),
                          border: Border.all(color: DesignTokens.line),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: AspectRatio(
                          aspectRatio: _aspectRatio ?? 16 / 9,
                          child: ColoredBox(
                            color: Colors.black,
                            child: state.playback == null
                                ? _LoadingState(
                                    state: state,
                                    onCancel: () => context.pop(),
                                  )
                                : _inPlayerControls(),
                          ),
                        ),
                      ),
                      const SizedBox(height: DesignTokens.space4),
                      if (state.phase == StreamingPhase.error)
                        _ErrorState(
                          message: state.message,
                          onRetry: _retry,
                          onBack: () => context.pop(),
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
                              ?.copyWith(color: DesignTokens.textSecondary),
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
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  void _stopOwnedSession() {
    final owned = _ownedSessionId;
    if (owned != null && _service.state.sessionId == owned) {
      unawaited(_service.stop());
    }
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (determinate)
              SizedBox(
                width: 200,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: stats.progress.clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(stats.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}% · ${formatBytes(stats.downloadedBytes)} of ${formatBytes(stats.totalBytes)}',
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
            Text(switch (state.phase) {
              StreamingPhase.resolving => 'Connecting to the source',
              StreamingPhase.buffering => 'Buffering the video',
              StreamingPhase.seeking => 'Loading the new position',
              _ => 'Preparing the local stream',
            }, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              state.phase == StreamingPhase.resolving
                  ? 'The first playback may need torrent information.'
                  : 'Playback begins as soon as enough video is ready.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: DesignTokens.textSecondary,
              ),
            ),
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
  });
  final String? message;
  final VoidCallback onRetry;
  final VoidCallback onBack;
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
            ],
          ),
        ],
      ),
    );
  }
}
