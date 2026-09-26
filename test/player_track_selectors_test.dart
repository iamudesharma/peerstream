import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:peerstream/features/player/player_track_selectors.dart';

void main() {
  const audioTracks = Tracks(
    audio: [AudioTrack('1', 'English', 'eng'), AudioTrack('2', 'Hindi', 'hin')],
  );
  const subtitleTracks = Tracks(
    subtitle: [
      SubtitleTrack('3', 'English', 'eng'),
      SubtitleTrack('4', 'Hindi', 'hin'),
    ],
  );

  testWidgets('audio language rows are tappable and select the chosen track', (
    tester,
  ) async {
    AudioTrack? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioTrackSelector(
            tracks: audioTracks,
            selectedId: '1',
            onSelected: (track) async => selected = track,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Audio track'));
    await tester.pumpAndSettle();
    expect(find.text('Audio language'), findsOneWidget);
    expect(find.text('hin · Hindi'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'hin · Hindi'));
    await tester.pumpAndSettle();

    expect(selected?.id, '2');
    expect(selected?.language, 'hin');
  });

  testWidgets(
    'subtitle language rows are tappable and select the chosen track',
    (tester) async {
      SubtitleTrack? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubtitleTrackSelector(
              tracks: subtitleTracks,
              selectedId: 'no',
              onSelected: (track) async => selected = track,
              onLoadLocal: () async {},
              onFindOnline: () async {},
              loadingOnline: false,
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Subtitle track'));
      await tester.pumpAndSettle();
      expect(find.text('Subtitles'), findsOneWidget);
      final hindiTrack = find.widgetWithText(ListTile, 'hin · Hindi');
      await tester.ensureVisible(hindiTrack);
      await tester.pumpAndSettle();
      await tester.tap(hindiTrack);
      await tester.pumpAndSettle();

      expect(selected?.id, '4');
      expect(selected?.language, 'hin');
    },
  );

  testWidgets('subtitle Off, On, local, and online choices stay actionable', (
    tester,
  ) async {
    final selected = <String>[];
    var localLoads = 0;
    var onlineSearches = 0;
    Future<void> openAndTap(String label) async {
      await tester.tap(find.byTooltip('Subtitle track'));
      await tester.pumpAndSettle();
      final row = find.widgetWithText(ListTile, label);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleTrackSelector(
            tracks: subtitleTracks,
            selectedId: 'no',
            onSelected: (track) async => selected.add(track.id),
            onLoadLocal: () async => localLoads++,
            onFindOnline: () async => onlineSearches++,
            loadingOnline: false,
          ),
        ),
      ),
    );

    await openAndTap('Off');
    await openAndTap('On');
    await openAndTap('Load subtitle file');
    await openAndTap('Find online');

    expect(selected, ['no', '3']);
    expect(localLoads, 1);
    expect(onlineSearches, 1);
  });
}
