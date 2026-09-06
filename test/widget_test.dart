import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/sources/source_selection_screen.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/providers/app_providers.dart';

void main() {
  testWidgets('unmatched content shows the source empty state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceResultsProvider.overrideWith((ref, request) async => const []),
        ],
        child: const MaterialApp(
          home: SourceSelectionScreen(
            mediaRef: MediaRef(id: 550, type: MediaType.movie),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No playable sources found'), findsOneWidget);
  });
}
