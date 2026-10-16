import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/player/playback_startup_panel.dart';
import 'package:peerstream/services/streaming/streaming_service.dart';

void main() {
  testWidgets(
    'slow startup offers a source change without stopping preparation',
    (tester) async {
      var switched = false;
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackStartupPanel(
              state: StreamingState(
                phase: StreamingPhase.resolving,
                detail: StreamingDetail.connectingPeers,
                startedAt: DateTime.now().subtract(const Duration(seconds: 11)),
              ),
              onCancel: () => cancelled = true,
              onSwitchSource: () => switched = true,
            ),
          ),
        ),
      );
      expect(find.text('Connecting to peers'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('Try another source'));
      expect(switched, isTrue);
      expect(cancelled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
