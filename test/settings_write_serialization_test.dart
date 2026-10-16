import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/settings/subtitles_screen.dart';
import 'package:peerstream/providers/settings_providers.dart';
import 'package:peerstream/services/settings/settings_store.dart';

void main() {
  testWidgets(
    'preferences retry recovers from unavailable storage without writing',
    (tester) async {
      var unavailable = true;
      var writes = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(
              () => AppSettingsNotifier(
                read: () async {
                  if (unavailable) throw StateError('SSD disconnected');
                  return const AppSettings();
                },
                write: (_) async {
                  writes++;
                },
              ),
            ),
          ],
          child: const MaterialApp(home: SubtitlesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Preferences unavailable'), findsOneWidget);
      unavailable = false;
      await tester.tap(find.byTooltip('Retry loading preferences'));
      await tester.pumpAndSettle();
      expect(find.text('Auto-load subtitles'), findsOneWidget);
      expect(find.text('Preferences unavailable'), findsNothing);
      expect(writes, 0);
    },
  );
  test(
    'rapid player settings retain both volume and speed after queued writes',
    () async {
      final firstWrite = Completer<void>();
      final saved = <AppSettings>[];
      final notifier = AppSettingsNotifier(
        read: () async => const AppSettings(),
        write: (value) async {
          saved.add(value);
          if (saved.length == 1) await firstWrite.future;
        },
      );
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final volume = notifier.setPlayerVolume(35);
      final speed = notifier.setPlayerRate(1.5);
      await Future<void>.delayed(Duration.zero);
      expect(saved.length, 1);
      firstWrite.complete();
      await Future.wait([volume, speed]);
      expect(saved.last.playerVolume, 35);
      expect(saved.last.playerRate, 1.5);
      expect(container.read(appSettingsProvider).value?.playerVolume, 35);
    },
  );

  test(
    'a failed preference write leaves state unchanged and allows retry',
    () async {
      var fail = true;
      final notifier = AppSettingsNotifier(
        read: () async => const AppSettings(),
        write: (_) async {
          if (fail) throw StateError('SSD unavailable');
        },
      );
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      await expectLater(notifier.setPlayerVolume(35), throwsStateError);
      expect(container.read(appSettingsProvider).value?.playerVolume, 100);
      fail = false;
      await notifier.setPlayerRate(1.5);
      expect(container.read(appSettingsProvider).value?.playerVolume, 100);
      expect(container.read(appSettingsProvider).value?.playerRate, 1.5);
    },
  );

  testWidgets(
    'subtitle settings report write failure without changing the toggle',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(
              () => AppSettingsNotifier(
                read: () async => const AppSettings(),
                write: (_) async => throw StateError('SSD unavailable'),
              ),
            ),
          ],
          child: const MaterialApp(home: SubtitlesScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auto-load subtitles'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save this change. Check storage and retry.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final switches = tester.widgetList<Switch>(find.byType(Switch));
      expect(switches.single.value, isFalse);
    },
  );
}
