import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/settings/http_server_section.dart';
import 'package:peerstream/providers/server_providers.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

void main() {
  testWidgets(
    'idle preview fits a narrow screen and refresh reads status again',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var checks = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            httpServerInfoProvider.overrideWith((ref) async {
              checks++;
              return checks == 1
                  ? const HttpServerInfo(status: HttpServerStatus.notStarted)
                  : HttpServerInfo(
                      status: HttpServerStatus.running,
                      url: Uri.parse('http://127.0.0.1:54321/stream/example/0'),
                    );
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: HttpServerSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not started'), findsOneWidget);
      expect(find.text('Copy URL'), findsNothing);
      await tester.tap(find.byTooltip('Refresh server status'));
      await tester.pumpAndSettle();
      expect(checks, 2);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Host: 127.0.0.1  ·  Port: 54321'), findsOneWidget);
      expect(
        find.text('http://127.0.0.1:54321/stream/example/0'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disables refresh while checking and displays failures', (
    tester,
  ) async {
    final response = Completer<HttpServerInfo>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          httpServerInfoProvider.overrideWith((ref) => response.future),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: HttpServerSection()),
          ),
        ),
      ),
    );
    expect(find.text('Checking…'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    response.completeError(StateError('diagnostic failed'));
    await tester.pumpAndSettle();
    expect(find.text('Unable to check'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
    );
  });
}
