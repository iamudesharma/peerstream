import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../services/experience/playback_experience.dart';

String timingKey(String torrentKey, int fileIndex) => '$torrentKey:$fileIndex';

Future<void> restorePlayerTiming(
  Player player,
  String key, [
  PlaybackExperience? experience,
]) async {
  final journal = experience ?? playbackExperience;
  await journal.load();
  final row = journal.section('timing')[key] as Map? ?? {};
  final platform = player.platform;
  if (platform is NativePlayer) {
    await platform.setProperty(
      'sub-delay',
      '${((row['subtitleMs'] as num?) ?? 0) / 1000}',
    );
    await platform.setProperty(
      'audio-delay',
      '${((row['audioMs'] as num?) ?? 0) / 1000}',
    );
  }
}

class PlayerTimingControls extends StatefulWidget {
  const PlayerTimingControls({
    this.experience,
    required this.player,
    required this.fileKey,
    super.key,
  });
  final PlaybackExperience? experience;
  final Player player;
  final String fileKey;
  @override
  State<PlayerTimingControls> createState() => _PlayerTimingControlsState();
}

class _PlayerTimingControlsState extends State<PlayerTimingControls> {
  PlaybackExperience get journal => widget.experience ?? playbackExperience;
  int _subtitle = 0;
  int _audio = 0;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final row = journal.section('timing')[widget.fileKey] as Map? ?? {};
    _subtitle = (row['subtitleMs'] as num?)?.toInt() ?? 0;
    _audio = (row['audioMs'] as num?)?.toInt() ?? 0;
  }

  Future<void> _adjust(bool subtitle, int delta, {bool reset = false}) async {
    if (_busy) return;
    final previous = subtitle ? _subtitle : _audio;
    final next = reset ? 0 : (previous + delta).clamp(-60000, 60000);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final platform = widget.player.platform;
      if (platform is! NativePlayer) {
        throw StateError('Timing unavailable for this player');
      }
      await platform.setProperty(
        subtitle ? 'sub-delay' : 'audio-delay',
        '${next / 1000}',
      );
      if (subtitle) {
        _subtitle = next;
      } else {
        _audio = next;
      }
      await journal.update((data) {
        final rows = Map<String, dynamic>.from(data['timing'] as Map? ?? {});
        rows.remove(widget.fileKey);
        rows[widget.fileKey] = {'subtitleMs': _subtitle, 'audioMs': _audio};
        while (rows.length > 128) {
          rows.remove(rows.keys.first);
        }
        data['timing'] = rows;
      });
    } catch (_) {
      _error = 'Could not apply or save timing.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String label, bool subtitle, int value, int step) => Column(
    children: [
      Text(
        '$label ${(value / 1000).toStringAsFixed(2)} s',
        semanticsLabel:
            '$label delay ${(value / 1000).toStringAsFixed(2)} seconds',
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '$label earlier',
            onPressed: _busy ? null : () => _adjust(subtitle, -step),
            icon: const Icon(Icons.remove),
          ),
          TextButton(
            onPressed: _busy ? null : () => _adjust(subtitle, 0, reset: true),
            child: const Text('Reset'),
          ),
          IconButton(
            tooltip: '$label later',
            onPressed: _busy ? null : () => _adjust(subtitle, step),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Synchronization'),
    children: [
      _row('Subtitle', true, _subtitle, 100),
      _row('Audio', false, _audio, 50),
      if (_error != null) Text(_error!),
    ],
  );
}
