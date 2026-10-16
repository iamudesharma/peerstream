import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/home/continue_watching_row.dart';
import 'package:peerstream/models/watch_progress.dart';
import 'package:peerstream/providers/app_providers.dart';

class _RecoverableHistory extends WatchHistory {
  static int reads = 0;
  @override
  Future<List<WatchEntry>> build() async {
    reads++;
    if (reads == 1) throw StateError('Disconnected storage');
    return [];
  }

  @override
  Future<void> save(WatchEntry entry) => throw StateError('Unexpected write');
  @override
  Future<void> remove(String key) => throw StateError('Unexpected write');
  @override
  Future<void> clear() => throw StateError('Unexpected write');
}

void main() {
  testWidgets(
    'unavailable history offers a read-only retry instead of showing empty history',
    (tester) async {
      _RecoverableHistory.reads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            watchHistoryProvider.overrideWith(_RecoverableHistory.new),
          ],
          child: const MaterialApp(home: Scaffold(body: ContinueWatchingRow())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue Watching unavailable'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry loading history'));
      await tester.pumpAndSettle();
      expect(_RecoverableHistory.reads, 2);
      expect(find.text('Continue Watching unavailable'), findsNothing);
    },
  );
}
