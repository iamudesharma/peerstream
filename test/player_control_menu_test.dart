import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:peerstream/features/player/player_control_menu.dart';
import 'package:peerstream/features/player/player_settings_menu.dart';
import 'package:peerstream/features/player/player_track_selectors.dart';

const _videoKey = ValueKey('video-bounds');

Widget _video(
  Widget controls, {
  Size size = const Size(560, 315),
  VoidCallback? onTap,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        key: _videoKey,
        width: size.width,
        height: size.height,
        child: PlayerMenuOverlay(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Align(alignment: Alignment.bottomRight, child: controls),
          ),
        ),
      ),
    ),
  ),
);

void _expectInsideVideo(WidgetTester tester) {
  final video = tester.getRect(find.byKey(_videoKey));
  final menu = tester.getRect(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Material && widget.color == const Color(0xf2232328),
        )
        .last,
  );
  expect(menu.left, greaterThanOrEqualTo(video.left));
  expect(menu.right, lessThanOrEqualTo(video.right));
  expect(menu.top, greaterThanOrEqualTo(video.top));
  expect(menu.bottom, lessThanOrEqualTo(video.bottom));
  expect(menu.width, lessThanOrEqualTo(256));
  expect(find.byType(Dialog), findsNothing);
  expect(find.byType(BottomSheet), findsNothing);
}

void main() {
  testWidgets(
    'online subtitle choices remain in the video and cancellation completes',
    (tester) async {
      int? selected;
      var searches = 0;
      await tester.pumpWidget(
        _video(
          SubtitleTrackSelector(
            tracks: const Tracks(),
            selectedId: 'no',
            onSelected: (_) async {},
            onLoadLocal: () async {},
            loadingOnline: false,
            onFindOnline: (context) async {
              searches++;
              selected = await PlayerMenuOverlay.showChoices<int>(
                context: context,
                title: 'Online subtitles',
                builder: (_, choose) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ListTile(title: Text('Online subtitles')),
                    ListTile(
                      title: const Text('English from provider'),
                      onTap: () => choose(1),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      Future<void> openOnline() async {
        await tester.tap(find.byTooltip('Subtitle track'));
        await tester.pumpAndSettle();
        final online = find.widgetWithText(ListTile, 'Find online');
        await tester.ensureVisible(online);
        await tester.tap(online);
        await tester.pumpAndSettle();
        _expectInsideVideo(tester);
      }

      await openOnline();
      await tester.tap(find.text('English from provider'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      await openOnline();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(searches, 2);
      expect(find.text('Online subtitles'), findsNothing);
    },
  );
  testWidgets(
    'compact audio menu stays inside the video and accepts a choice after the toolbar is removed',
    (tester) async {
      final visible = ValueNotifier(true);
      final size = ValueNotifier(const Size(560, 315));
      addTearDown(visible.dispose);
      addTearDown(size.dispose);
      String? selected;
      await tester.pumpWidget(
        ValueListenableBuilder<Size>(
          valueListenable: size,
          builder: (_, videoSize, child) => _video(child!, size: videoSize),
          child: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, child) => show ? child! : const SizedBox(),
            child: AudioTrackSelector(
              tracks: const Tracks(
                audio: [
                  AudioTrack('1', null, null),
                  AudioTrack('2', null, null),
                ],
              ),
              selectedId: '1',
              onSelected: (track) async => selected = track.id,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Audio track'));
      await tester.pumpAndSettle();
      _expectInsideVideo(tester);
      visible.value = false;
      size.value = const Size(320, 180);
      await tester.pumpAndSettle();
      _expectInsideVideo(tester);
      await tester.ensureVisible(find.widgetWithText(ListTile, 'Track 2'));
      await tester.tap(find.widgetWithText(ListTile, 'Track 2'));
      await tester.pumpAndSettle();
      expect(selected, '2');
      expect(find.text('Audio language'), findsNothing);
    },
  );

  testWidgets(
    'long subtitle menus scroll within a small video and keep rows clickable',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        _video(
          SubtitleTrackSelector(
            tracks: Tracks(
              subtitle: [
                for (var id = 1; id <= 12; id++)
                  SubtitleTrack('$id', null, null),
              ],
            ),
            selectedId: 'no',
            onSelected: (track) async => selected = track.id,
            onLoadLocal: () async {},
            onFindOnline: (_) async {},
            loadingOnline: false,
          ),
          size: const Size(320, 180),
        ),
      );
      await tester.tap(find.byTooltip('Subtitle track'));
      await tester.pumpAndSettle();
      _expectInsideVideo(tester);
      final lastTrack = find.widgetWithText(ListTile, 'Track 12');
      await tester.ensureVisible(lastTrack);
      await tester.pumpAndSettle();
      await tester.tap(lastTrack);
      await tester.pumpAndSettle();
      expect(selected, '12');
    },
  );

  testWidgets(
    'speed submenu stays in the video and outside clicks only dismiss the menu',
    (tester) async {
      var videoTaps = 0;
      double? speed;
      await tester.pumpWidget(
        _video(
          PlayerSettingsMenu(
            rate: 1,
            onRateSelected: (value) => speed = value,
            fit: BoxFit.contain,
            aspectRatio: null,
            onToggleMute: () {},
            onFitSelected: (_) {},
            onAspectRatioSelected: (_) {},
            onShowShortcuts: () {},
            onToggleStats: () {},
            statsEnabled: false,
          ),
          onTap: () => videoTaps++,
        ),
      );
      await tester.tap(find.byTooltip('Player settings'));
      await tester.pumpAndSettle();
      _expectInsideVideo(tester);
      await tester.tap(find.text('Playback speed'));
      await tester.pumpAndSettle();
      _expectInsideVideo(tester);
      final choice = find.widgetWithText(ListTile, '1.5×');
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(speed, 1.5);
      await tester.tap(find.byTooltip('Player settings'));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getTopLeft(find.byKey(_videoKey)) + const Offset(8, 8),
      );
      await tester.pumpAndSettle();
      expect(find.text('Playback speed'), findsNothing);
      expect(videoTaps, 0);
    },
  );
}
