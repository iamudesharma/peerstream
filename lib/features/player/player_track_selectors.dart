import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'player_control_menu.dart';
import 'live_player_tracks.dart';

List<AudioTrack> realAudioTracks(Tracks tracks) => tracks.audio
    .where((track) => track.id != 'auto' && track.id != 'no')
    .toList();

List<SubtitleTrack> realSubtitleTracks(Tracks tracks) => tracks.subtitle
    .where((track) => track.id != 'auto' && track.id != 'no')
    .toList();

String controlsTrackLabel(String id, String? title, String? language) {
  if (id == 'no') return 'Off';
  if (id == 'auto') return 'Auto';
  final values = [
    if (language != null && language.isNotEmpty) language,
    if (title != null && title.isNotEmpty) title,
  ];
  return values.isEmpty ? 'Track $id' : values.join(' · ');
}

String _trackDetails(dynamic track) {
  final details = <String>[
    if (track.codec is String && track.codec.isNotEmpty) track.codec as String,
    if (track.channels is String && track.channels.isNotEmpty)
      track.channels as String,
  ];
  return details.join(' · ');
}

class AudioTrackSelector extends StatelessWidget {
  const AudioTrackSelector({
    required this.tracks,
    required this.selectedId,
    required this.onSelected,
    this.player,
    super.key,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(AudioTrack) onSelected;
  final Player? player;

  void _select(AudioTrack track, VoidCallback close) {
    close();
    unawaited(onSelected(track));
  }

  @override
  Widget build(BuildContext context) => PlayerControlMenu(
    tooltip: 'Audio track',
    icon: const Icon(Icons.multitrack_audio),
    menuBuilder: (context, close) => _LiveTrackMenu(
      player: player,
      tracks: tracks,
      selectedId: selectedId,
      audio: true,
      builder: (tracks, selectedId) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Audio language')),
          _AudioTrackTile(
            track: AudioTrack.auto(),
            selected: selectedId == 'auto',
            onTap: () => _select(AudioTrack.auto(), close),
          ),
          if (realAudioTracks(tracks).isEmpty)
            const ListTile(
              enabled: false,
              title: Text('No embedded audio tracks'),
            ),
          for (final track in realAudioTracks(tracks))
            _AudioTrackTile(
              track: track,
              selected: selectedId == track.id,
              onTap: () => _select(track, close),
            ),
        ],
      ),
    ),
  );
}

class _AudioTrackTile extends StatelessWidget {
  const _AudioTrackTile({
    required this.track,
    required this.selected,
    required this.onTap,
  });

  final AudioTrack track;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(controlsTrackLabel(track.id, track.title, track.language)),
    subtitle: _trackDetails(track).isEmpty ? null : Text(_trackDetails(track)),
    selected: selected,
    trailing: selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}

class SubtitleTrackSelector extends StatelessWidget {
  const SubtitleTrackSelector({
    required this.tracks,
    required this.selectedId,
    required this.onSelected,
    required this.onLoadLocal,
    required this.onFindOnline,
    required this.loadingOnline,
    this.player,
    super.key,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(SubtitleTrack) onSelected;
  final Future<void> Function() onLoadLocal;
  final Future<void> Function(BuildContext) onFindOnline;
  final bool loadingOnline;
  final Player? player;

  @override
  Widget build(BuildContext context) {
    return PlayerControlMenu(
      tooltip: 'Subtitle track',
      icon: Icon(
        selectedId == 'no'
            ? Icons.subtitles_off_outlined
            : Icons.subtitles_outlined,
      ),
      menuBuilder: (context, close) {
        void select(SubtitleTrack track) {
          close();
          unawaited(onSelected(track));
        }

        return _LiveTrackMenu(
          player: player,
          tracks: tracks,
          selectedId: selectedId,
          audio: false,
          builder: (tracks, selectedId) {
            final available = realSubtitleTracks(tracks);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(title: Text('Subtitles')),
                ListTile(
                  title: const Text('Off'),
                  trailing: selectedId == 'no' ? const Icon(Icons.check) : null,
                  onTap: () => select(SubtitleTrack.no()),
                ),
                ListTile(
                  title: const Text('On'),
                  enabled: available.isNotEmpty,
                  trailing: selectedId != 'no' && available.isNotEmpty
                      ? const Icon(Icons.check)
                      : null,
                  onTap: available.isEmpty
                      ? null
                      : () => select(available.first),
                ),
                if (available.isEmpty)
                  const ListTile(
                    enabled: false,
                    title: Text('No embedded subtitles'),
                  ),
                for (final track in available)
                  ListTile(
                    title: Text(
                      controlsTrackLabel(track.id, track.title, track.language),
                    ),
                    subtitle: _trackDetails(track).isEmpty
                        ? null
                        : Text(_trackDetails(track)),
                    trailing: selectedId == track.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => select(track),
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('Load subtitle file'),
                  onTap: () {
                    close();
                    unawaited(onLoadLocal());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.search),
                  title: Text(
                    loadingOnline ? 'Finding subtitles…' : 'Find online',
                  ),
                  enabled: !loadingOnline,
                  onTap: loadingOnline
                      ? null
                      : () {
                          close();
                          unawaited(onFindOnline(context));
                        },
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The popup keeps its own live subscription after media_kit removes the
/// toolbar, so late track discovery and native selections still update it.
class _LiveTrackMenu extends StatelessWidget {
  const _LiveTrackMenu({
    required this.player,
    required this.tracks,
    required this.selectedId,
    required this.audio,
    required this.builder,
  });

  final Player? player;
  final Tracks tracks;
  final String selectedId;
  final bool audio;
  final Widget Function(Tracks, String) builder;

  @override
  Widget build(BuildContext context) {
    final current = player;
    if (current == null) return builder(tracks, selectedId);
    return LivePlayerTracks(
      tracks: current.stream.tracks,
      selection: current.stream.track,
      currentTracks: () => current.state.tracks,
      currentSelection: () => current.state.track,
      builder: (context, tracks, selection) =>
          builder(tracks, audio ? selection.audio.id : selection.subtitle.id),
    );
  }
}
