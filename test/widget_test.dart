import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/features/sources/source_selection_screen.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/providers/app_providers.dart';
import 'package:peerstream/services/torrent/source_discovery.dart';

void main() {
  testWidgets('unmatched content shows the source empty state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The sources screen performs a single incremental discovery pass;
          // override that stream with an immediately-complete empty result.
          sourceDiscoveryProvider.overrideWith(
            (ref, request) => Stream.value(
              const IncrementalDiscoveryState(isComplete: true),
            ),
          ),
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
