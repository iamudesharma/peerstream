import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/app.dart';

void main() {
  group('performAppExit', () {
    test('persists before tearing down, then votes to exit', () async {
      final events = <String>[];
      final response = await performAppExit(
        persistState: () async {
          events.add('persist');
        },
        stopPlayer: () async {
          events.add('stop');
        },
        disposeServices: () async {
          events.add('dispose');
        },
        settleDelay: Duration.zero,
      );
      expect(response, AppExitResponse.exit);
      expect(events, ['persist', 'stop', 'dispose']);
    });

    test('a failing persist still stops and disposes', () async {
      final events = <String>[];
      final response = await performAppExit(
        persistState: () => throw StateError('disk gone'),
        stopPlayer: () async {
          events.add('stop');
        },
        disposeServices: () async {
          events.add('dispose');
        },
        settleDelay: Duration.zero,
      );
      expect(response, AppExitResponse.exit);
      expect(events, ['stop', 'dispose']);
    });

    test('a failing stop still disposes', () async {
      final events = <String>[];
      final response = await performAppExit(
        persistState: () async {
          events.add('persist');
        },
        stopPlayer: () => throw StateError('player gone'),
        disposeServices: () async {
          events.add('dispose');
        },
        settleDelay: Duration.zero,
      );
      expect(response, AppExitResponse.exit);
      expect(events, ['persist', 'dispose']);
    });
  });

  // Regression test for the quit-time teardown race: exit dispatch awaits
  // each observer in turn, so tree teardown can run mid-dispatch. Production
  // keeps a single app-lifetime (never disposed) listener; this test mirrors
  // that structure — async gaps in the exit callback plus a concurrent tree
  // teardown — and requires a clean exit with no used-after-dispose
  // assertion. A State-owned listener disposed mid-dispatch throws exactly
  // the reported `AppLifecycleListener was used after being disposed` error
  // here instead.
  testWidgets('exit dispatch survives tree teardown without assertion',
      (tester) async {
    final events = <String>[];
    // Mirrors main(): app-lifetime listener, never disposed.
    AppLifecycleListener(
      onExitRequested: () => performAppExit(
        persistState: () async {
          events.add('persist');
        },
        stopPlayer: () async {
          events.add('stop');
        },
        disposeServices: () async {
          events.add('dispose');
        },
        settleDelay: const Duration(milliseconds: 10),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    final exitFuture = tester.binding.handleRequestAppExit();
    // Tear the tree down mid-dispatch, like engine teardown during quit.
    await tester.pumpWidget(Container());
    AppExitResponse? response;
    exitFuture.then((value) => response = value);
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pump(const Duration(milliseconds: 25));
    expect(response, AppExitResponse.exit);
    expect(events, ['persist', 'stop', 'dispose']);
    expect(tester.takeException(), isNull);
  });
}
