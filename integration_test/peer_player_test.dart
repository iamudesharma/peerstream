import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';

import 'default_player_test.dart' as fixture;

void main(List<String> arguments) {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  MediaKit.ensureInitialized();
  testWidgets('original local peer magnet reaches default player', (
    tester,
  ) async {
    expect(arguments.length, 2);
    final uri = Uri.parse(arguments[1]);
    expect(uri.scheme, 'magnet');
    expect(uri.queryParameters['x.pe'], startsWith('127.0.0.1:'));
    final result = await fixture.runPlayerMatrixTrial(
      tester,
      backend: arguments[0],
      kind: 'peer',
      sourceOverride: TorrentSource(
        id: 'original-local-peer',
        content: const MediaRef(id: -90909, type: MediaType.movie),
        name: 'Original loopback BitTorrent peer fixture',
        uri: uri,
        inputType: TorrentInputType.magnet,
        providerName: 'Original generated fixture',
        attribution: 'Original fixture',
        license: 'CC0',
        provenanceUrl: Uri.parse('about:blank'),
      ),
    );
    binding.reportData = {'peer': result};
    debugPrint('[PeerVerification] ${jsonEncode(result)}');
    expect(result['visiblePlaybackMs'], lessThanOrEqualTo(10000));
    expect(result['sourceLookups'], 0);
    expect(result['playableScheme'], 'http');
  });
}
