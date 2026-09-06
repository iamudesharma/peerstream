import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:peerstream/features/player/live_player_tracks.dart';

void main() {
  testWidgets('retained controls receive late tracks and confirmed selection', (
    tester,
  ) async {
    final tracks = StreamController<Tracks>.broadcast();
    final selection = StreamController<Track>.broadcast();
    addTearDown(tracks.close);
    addTearDown(selection.close);
    var current = const Tracks();
    var selected = const Track();
    Widget controls() => MaterialApp(
      home: LivePlayerTracks(
        tracks: tracks.stream,
        selection: selection.stream,
        currentTracks: () => current,
        currentSelection: () => selected,
        builder: (context, available, active) => Text(
          '${available.audio.map((t) => t.id).join(',')} / '
          '${available.subtitle.map((t) => t.id).join(',')} / '
          '${active.audio.id}:${active.subtitle.id}',
        ),
      ),
    );
    await tester.pumpWidget(controls());
    expect(find.text('auto,no / auto,no / auto:auto'), findsOneWidget);
    current = const Tracks(
      audio: [
        AudioTrack('1', 'English', 'eng'),
        AudioTrack('2', 'Hindi', 'hin'),
      ],
      subtitle: [SubtitleTrack('3', 'English', 'eng')],
    );
    tracks.add(current);
    await tester.pump();
    expect(find.text('1,2 / 3 / auto:auto'), findsOneWidget);
    selected = const Track(
      audio: AudioTrack('2', 'Hindi', 'hin'),
      subtitle: SubtitleTrack('3', 'English', 'eng'),
    );
    selection.add(selected);
    await tester.pump();
    await tester.pump();
    expect(find.text('1,2 / 3 / 2:3'), findsOneWidget);
    // A new fullscreen overlay must initialize from the current player state.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(controls());
    expect(find.text('1,2 / 3 / 2:3'), findsOneWidget);
  });
}
