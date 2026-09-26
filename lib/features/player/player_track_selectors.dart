import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

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
    super.key,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(AudioTrack) onSelected;

  Future<void> _showTracks(BuildContext context) async {
    final available = realAudioTracks(tracks);
    final selected = await showModalBottomSheet<AudioTrack>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
          ),
          child: ListView(
            children: [
              const ListTile(title: Text('Audio language')),
              _AudioTrackTile(
                track: AudioTrack.auto(),
                selected: selectedId == 'auto',
                onTap: () => Navigator.pop(sheetContext, AudioTrack.auto()),
              ),
              if (available.isEmpty)
                const ListTile(
                  enabled: false,
                  title: Text('No embedded audio tracks'),
                ),
              for (final track in available)
                _AudioTrackTile(
                  track: track,
                  selected: selectedId == track.id,
                  onTap: () => Navigator.pop(sheetContext, track),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) await onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Audio track',
    onPressed: () => _showTracks(context),
    icon: const Icon(Icons.multitrack_audio),
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
    trailing: selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}

enum _SubtitleAction { off, on, track, local, online }

class _SubtitleSelection {
  const _SubtitleSelection(this.action, [this.track]);

  final _SubtitleAction action;
  final SubtitleTrack? track;
}

class SubtitleTrackSelector extends StatelessWidget {
  const SubtitleTrackSelector({
    required this.tracks,
    required this.selectedId,
    required this.onSelected,
    required this.onLoadLocal,
    required this.onFindOnline,
    required this.loadingOnline,
    super.key,
  });

  final Tracks tracks;
  final String selectedId;
  final Future<void> Function(SubtitleTrack) onSelected;
  final Future<void> Function() onLoadLocal;
  final Future<void> Function() onFindOnline;
  final bool loadingOnline;

  Future<void> _showTracks(BuildContext context) async {
    final available = realSubtitleTracks(tracks);
    final selection = await showModalBottomSheet<_SubtitleSelection>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
          ),
          child: ListView(
            children: [
              const ListTile(title: Text('Subtitles')),
              ListTile(
                title: const Text('Off'),
                trailing: selectedId == 'no' ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  const _SubtitleSelection(_SubtitleAction.off),
                ),
              ),
              ListTile(
                title: const Text('On'),
                enabled: available.isNotEmpty,
                trailing: selectedId != 'no' && available.isNotEmpty
                    ? const Icon(Icons.check)
                    : null,
                onTap: available.isEmpty
                    ? null
                    : () => Navigator.pop(
                        sheetContext,
                        const _SubtitleSelection(_SubtitleAction.on),
                      ),
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
                  onTap: () => Navigator.pop(
                    sheetContext,
                    _SubtitleSelection(_SubtitleAction.track, track),
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Load subtitle file'),
                onTap: () => Navigator.pop(
                  sheetContext,
                  const _SubtitleSelection(_SubtitleAction.local),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.search),
                title: Text(
                  loadingOnline ? 'Finding subtitles…' : 'Find online',
                ),
                enabled: !loadingOnline,
                onTap: loadingOnline
                    ? null
                    : () => Navigator.pop(
                        sheetContext,
                        const _SubtitleSelection(_SubtitleAction.online),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selection == null) return;
    switch (selection.action) {
      case _SubtitleAction.off:
        await onSelected(SubtitleTrack.no());
      case _SubtitleAction.on:
        if (available.isNotEmpty) await onSelected(available.first);
      case _SubtitleAction.track:
        final track = selection.track;
        if (track != null) await onSelected(track);
      case _SubtitleAction.local:
        await onLoadLocal();
      case _SubtitleAction.online:
        await onFindOnline();
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Subtitle track',
    onPressed: () => _showTracks(context),
    icon: Icon(
      selectedId == 'no'
          ? Icons.subtitles_off_outlined
          : Icons.subtitles_outlined,
    ),
  );
}
