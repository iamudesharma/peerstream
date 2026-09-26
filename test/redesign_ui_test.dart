import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:peerstream/core/theme.dart';
import 'package:peerstream/core/widgets/app_scaffold.dart';
import 'package:peerstream/core/widgets/media_card.dart';
import 'package:peerstream/core/widgets/section_header.dart';
import 'package:peerstream/features/home/featured_media.dart';
import 'package:peerstream/features/player/player_settings_menu.dart';
import 'package:peerstream/models/media_item.dart';

const _item = MediaItem(
  id: 1,
  type: MediaType.movie,
  title: 'A very long movie title to check responsive artwork and headings',
  overview: 'A story worth discovering. A longer description should remain readable on small screens without pushing the action out of the card.',
  releaseDate: '2026-01-01',
  rating: 8.5,
);

void main() {
  for (final width in [320.0, 600.0, 1024.0, 1440.0]) {
    testWidgets('discovery components fit at $width with larger text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPeerStreamTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 1000),
              textScaler: const TextScaler.linear(1.5),
            ),
            child: AppScaffold(
              selectedIndex: 0,
              body: ListView(
                children: [
                  const FeaturedMedia(item: _item),
                  SectionHeader(
                    title: 'A collection with a longer title',
                    onSeeAll: () {},
                  ),
                  const SizedBox(
                    height: 380,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: MediaCard(item: _item),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Explore title'), findsOneWidget);
      expect(
        find.byType(NavigationBar),
        width < 900 ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('navigation and featured title open their real routes', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => AppScaffold(
            selectedIndex: 0,
            body: ListView(children: const [FeaturedMedia(item: _item)]),
          ),
        ),
        GoRoute(
          path: '/search',
          builder: (_, _) => const Text('Search destination'),
        ),
        GoRoute(
          path: '/details/movie/1',
          builder: (_, _) => const Text('Details destination'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: buildPeerStreamTheme(), routerConfig: router),
    );
    await tester.tap(find.text('Explore title'));
    await tester.pumpAndSettle();
    expect(find.text('Details destination'), findsOneWidget);
    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Search destination'), findsOneWidget);
  });

  testWidgets('player settings select speed and fit through submenus', (
    tester,
  ) async {
    var rate = 1.0;
    var fit = BoxFit.contain;
    var stats = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPeerStreamTheme(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => PlayerSettingsMenu(
                rate: rate,
                onRateSelected: (value) => setState(() => rate = value),
                fit: fit,
                aspectRatio: null,
                onFitSelected: (value) => setState(() => fit = value),
                onAspectRatioSelected: (_) {},
                onToggleMute: () {},
                onShowShortcuts: () {},
                onToggleStats: () => setState(() => stats = !stats),
                statsEnabled: stats,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Player settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(rate, 1.5);
    await tester.tap(find.byTooltip('Player settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video fit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fill screen'));
    await tester.pumpAndSettle();
    expect(fit, BoxFit.cover);
    await tester.tap(find.byTooltip('Player settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playback statistics'));
    await tester.pumpAndSettle();
    expect(stats, isTrue);
    expect(tester.takeException(), isNull);
  });
}
