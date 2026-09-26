import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_video_player/dartnative_video_player.dart';

import '../../core/icons.dart';
import '../../core/navigation.dart';
import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../providers/app_store.dart';
import '../../services/streaming/streaming_service.dart';

/// Plays a resolved torrent through the loopback HTTP server.
///
/// The platform player is AVPlayer on iOS and ExoPlayer on Android. Sources
/// those engines cannot decode fail with the streaming error message instead
/// of spinning.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
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
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _store = AppStore.instance;
  VideoPlayerController? _controller;
  StreamSubscription<StreamingState>? _states;
  StreamSubscription<VideoEvent>? _events;
  Timer? _positionTimer;
  int? _sessionId;
  String? _openedUri;
  String? _failure;
  bool _opening = true;

  @override
  void initState() {
    super.initState();
    _states = _store.streaming.states.listen((_) {
      if (mounted) setState(_syncPlayer);
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final source = await _resolveSource();
      if (!mounted) return;
      if (source == null) {
        setState(() {
          _opening = false;
          _failure = 'No playable source was found.';
        });
        return;
      }
      final token = _store.streaming.beginSession(source);
      _sessionId = token.id;
      await _store.streaming.start(
        source,
        claimed: token,
        startPositionMs: widget.resumeMs,
      );
      if (mounted) setState(_syncPlayer);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _failure = '$error';
      });
    }
  }

  Future<TorrentSource?> _resolveSource() async {
    final initial = widget.initialSource;
    if (initial != null) return initial;
    final results = await _store.sourceResults((
      media: widget.mediaRef,
      season: widget.season,
      episode: widget.episode,
    ));
    final sources = results.expand((result) => result.sources);
    for (final source in sources) {
      if (source.id == widget.sourceId) return source;
    }
    return sources.isEmpty ? null : sources.first;
  }

  void _syncPlayer() {
    final playback = _store.streaming.state.playback;
    final uri = playback?.uri.toString();
    final phase = _store.streaming.state.phase;
    if (phase == StreamingPhase.error || phase == StreamingPhase.unsupported) {
      _failure = _store.streaming.state.message ?? 'Playback failed.';
      _opening = false;
    }
    if (uri == null || uri == _openedUri) return;
    _openedUri = uri;
    _opening = false;
    _controller?.dispose();
    final controller = VideoPlayerController(
      dataSource: VideoDataSource.network(
        uri,
        cacheConfig: VideoCacheConfig.none,
      ),
      autoPlay: true,
    );
    _controller = controller;
    _events?.cancel();
    _events = controller.events.listen(_onVideoEvent);
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!controller.isInitialized) return;
      _store.streaming.reportPlaybackPosition(controller.positionMs);
    });
  }

  void _onVideoEvent(VideoEvent event) {
    final streaming = _store.streaming;
    switch (event.type) {
      case VideoEventType.initialized:
        final duration = event.durationMs ?? _controller?.durationMs ?? 0;
        if (duration > 0) streaming.reportDurationMs(duration);
        final resume = widget.resumeMs;
        if (resume != null && resume > 0) {
          streaming.reportSeekStarted();
          _controller?.seekTo(Duration(milliseconds: resume));
          streaming.reportPlaybackPosition(resume);
          streaming.reportSeekSettled();
        }
        streaming.markPlaying();
        break;
      case VideoEventType.bufferingStart:
        streaming.reportBuffering(true);
        break;
      case VideoEventType.bufferingEnd:
        streaming.reportBuffering(false);
        break;
      case VideoEventType.error:
        final message =
            event.errorMessage ??
            'This file cannot be played on the platform player.';
        streaming.reportError(message);
        if (mounted) {
          setState(() => _failure = message);
        }
        break;
      case VideoEventType.play:
      case VideoEventType.pause:
      case VideoEventType.completed:
      case VideoEventType.bufferingUpdate:
      case VideoEventType.seekComplete:
        break;
    }
  }

  void _toggle() {
    final controller = _controller;
    if (controller == null || !controller.isInitialized) return;
    if (controller.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    setState(() {});
  }

  void _seekBy(int seconds) {
    final controller = _controller;
    if (controller == null || !controller.isInitialized) return;
    final next = controller.positionMs + seconds * 1000;
    final clamped = next < 0 ? 0 : next;
    _store.streaming.reportSeekStarted();
    controller.seekTo(Duration(milliseconds: clamped));
    _store.streaming.reportPlaybackPosition(clamped);
    _store.streaming.reportSeekSettled();
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    unawaited(_events?.cancel() ?? Future.value());
    unawaited(_states?.cancel() ?? Future.value());
    _controller?.dispose();
    final session = _sessionId;
    if (session != null) _store.streaming.cancelSession(session);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final message = _failure ?? _store.streaming.state.message;
    return Scaffold(
      brightness: Brightness.dark,
      backgroundColor: const Color(0xFF000000),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            SizedBox.expand(
              child: VideoPlayer(controller: controller, fit: BoxFit.contain),
            )
          else
            const SizedBox.expand(),
          if (controller == null)
            Center(
              child: _opening
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        message ?? 'Playback failed.',
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          Positioned(
            left: 8,
            top: 8,
            child: IconButton(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.arrow_back, color: Color(0xFFFFFFFF)),
            ),
          ),
          if (controller != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () => _seekBy(-10),
                    icon: const Icon(Icons.replay_10, color: Color(0xFFFFFFFF)),
                  ),
                  IconButton(
                    onPressed: _toggle,
                    icon: Icon(
                      controller.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: const Color(0xFFFFFFFF),
                      size: 36,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _seekBy(10),
                    icon: const Icon(Icons.forward_10, color: Color(0xFFFFFFFF)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
