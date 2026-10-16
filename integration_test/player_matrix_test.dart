import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'default_player_test.dart' as fixture;

void main(List<String> arguments) {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.platformDispatcher.semanticsEnabledTestValue = true;
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);
  MediaKit.ensureInitialized();
  final backend = arguments.isEmpty ? 'native' : arguments[0];
  final kind = arguments.length < 2 ? 'cold' : arguments[1];
  testWidgets('controlled default player $backend $kind', (tester) async {
    final result = await fixture.runPlayerMatrixTrial(
      tester,
      backend: backend,
      kind: kind,
    );
    binding.reportData = {'matrix': result};
    // Also retain results when another acceptance assertion fails later.
    debugPrint('[MatrixVerification] ${jsonEncode(result)}');
  });
}
