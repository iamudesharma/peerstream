import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../models/torrent_models.dart';
import '../../providers/app_providers.dart';
import '../../services/streaming/streaming_service.dart';
import '../../services/video/desktop_video.dart';
import '../../services/video/external_playback.dart';

Future<ExternalVideoPlayer?> chooseExternalVideoPlayer(
  BuildContext context, {
  DesktopVideo desktop = const DesktopVideo(),
}) async {
  final players = await desktop.players();
  if (!context.mounted) return null;
  final selected = await showDialog<ExternalVideoPlayer>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Play in another player'),
      children: [
        for (final player in players)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, player),
            child: ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(player.name),
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(
            context,
            const ExternalVideoPlayer('', 'Choose application…'),
          ),
          child: const ListTile(
            leading: Icon(Icons.apps),
            title: Text('Choose application…'),
            subtitle: Text('VLC, IINA, or another compatible player'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'PeerStream must stay open while streaming. Audio, subtitles and playback position are controlled in the external app.',
          ),
        ),
      ],
    ),
  );
  return selected?.id == '' ? desktop.choosePlayer() : selected;
}

class ExternalPlayerRequest {
  const ExternalPlayerRequest(this.source, this.player);
  final TorrentSource source;
  final ExternalVideoPlayer player;
}

class ExternalPlayerScreen extends ConsumerStatefulWidget {
  const ExternalPlayerScreen({required this.request, super.key});
  final ExternalPlayerRequest request;
  @override
  ConsumerState<ExternalPlayerScreen> createState() =>
      _ExternalPlayerScreenState();
}

class _ExternalPlayerScreenState extends ConsumerState<ExternalPlayerScreen> {
  late final ExternalPlayback _session;
  bool _sent = false;
  bool _leaving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _session = ExternalPlayback(
      ref.read(streamingServiceProvider),
      const DesktopVideo(),
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final policy = await ref.read(sourcePolicyProvider.future);
      if (!mounted) return;
      if (!policy.allows(widget.request.source)) {
        throw StateError('This source is blocked by your source settings.');
      }
      await _session.start(widget.request.source, widget.request.player);
      if (mounted) setState(() => _sent = true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError ? error.message.toString() : 'The video could not be opened. Check the source and selected player.',
        );
      }
    }
  }

  Future<void> _stop() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _session.close();
      if (mounted) {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/');
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _leaving = false;
          _error = 'Could not stop streaming. Reconnect storage and retry.';
        });
      }
    }
  }

  @override
  void dispose() {
    unawaited(_session.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state =
        ref.watch(streamingStateProvider).value ?? _session.service.state;
    final error =
        _error ?? (state.phase == StreamingPhase.error ? state.message : null);
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_stop());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.request.player.name),
          leading: IconButton(
            tooltip: 'Stop external stream and go back',
            icon: const Icon(Icons.arrow_back),
            onPressed: _leaving ? null : _stop,
          ),
        ),
        body: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_sent && error == null)
                    const CircularProgressIndicator()
                  else
                    Icon(
                      error == null ? Icons.open_in_new : Icons.error_outline,
                      size: 48,
                    ),
                  const SizedBox(height: 20),
                  Text(
                    widget.request.source.name,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error ??
                        (_sent
                            ? 'Sent to ${widget.request.player.name}. Keep PeerStream open until you finish watching.'
                            : 'Preparing the video for ${widget.request.player.name}…'),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  if (state.stats.downloadRate > 0)
                    Text(
                      '${formatSpeed(state.stats.downloadRate)} · ${state.stats.peers ?? 0} peers',
                    ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _leaving ? null : _stop,
                    icon: const Icon(Icons.stop),
                    label: Text(_leaving ? 'Stopping…' : 'Stop streaming'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Use the external player for seeking, audio and subtitles. Stopping closes the stream. The external player may continue using buffered video or a downloaded file.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
