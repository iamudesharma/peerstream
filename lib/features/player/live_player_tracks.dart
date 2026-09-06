import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

/// Subscribe inside the controls overlay: media_kit_video 2.0.1 retains its
/// theme's button widgets when the parent supplies a new theme.
class LivePlayerTracks extends StatelessWidget {
  const LivePlayerTracks({
    required this.tracks,
    required this.selection,
    required this.currentTracks,
    required this.currentSelection,
    required this.builder,
    super.key,
  });

  final Stream<Tracks> tracks;
  final Stream<Track> selection;
  final Tracks Function() currentTracks;
  final Track Function() currentSelection;
  final Widget Function(BuildContext, Tracks, Track) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<Tracks>(
    stream: tracks,
    initialData: currentTracks(),
    builder: (context, available) => StreamBuilder<Track>(
      stream: selection,
      initialData: currentSelection(),
      builder: (context, selected) =>
          builder(context, available.data!, selected.data!),
    ),
  );
}
