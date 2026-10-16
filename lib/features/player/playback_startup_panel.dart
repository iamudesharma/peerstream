import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/streaming/streaming_service.dart';

/// Uses actual phases; downloading a percentage of the file is not startup progress.
class PlaybackStartupPanel extends StatefulWidget {
  const PlaybackStartupPanel({
    required this.state,
    required this.onCancel,
    required this.onSwitchSource,
    super.key,
  });
  final StreamingState state;
  final VoidCallback onCancel;
  final VoidCallback onSwitchSource;
  @override
  State<PlaybackStartupPanel> createState() => _PlaybackStartupPanelState();
}

class _PlaybackStartupPanelState extends State<PlaybackStartupPanel> {
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

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final elapsed = state.startedAt == null
        ? Duration.zero
        : DateTime.now().difference(state.startedAt!);
    final label = switch (state.detail) {
      StreamingDetail.findingSources => 'Finding video',
      StreamingDetail.connectingPeers => 'Connecting to peers',
      StreamingDetail.reconnecting => 'Reconnecting',
      _ => state.playback == null ? 'Preparing video' : 'Buffering first frame',
    };
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.phase != StreamingPhase.error)
                const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: Text(label)),
              const SizedBox(height: 8),
              Text(
                state.message ?? 'Playback starts as soon as the required video data is ready.',
                textAlign: TextAlign.center,
              ),
              if (elapsed.inSeconds >= 10) ...[
                const SizedBox(height: 8),
                const Text(
                  'This source is taking longer than usual.',
                  textAlign: TextAlign.center,
                ),
                TextButton.icon(
                  onPressed: widget.onSwitchSource,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Try another source'),
                ),
              ],
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
