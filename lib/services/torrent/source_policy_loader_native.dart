import 'dart:io';

import 'source_policy.dart';

const _configuredPath = String.fromEnvironment(
  'SOURCE_BLOCKLIST_PATH',
  defaultValue: 'config/source_blocklist.json',
);

Future<SourcePolicy> loadSourcePolicy() async {
  final file = File(_configuredPath);
  if (!await file.exists()) return const SourcePolicy();
  try {
    return SourcePolicy.fromJsonString(await file.readAsString());
  } on FormatException catch (error) {
    throw FormatException(
      'Invalid source blocklist at $_configuredPath: $error',
    );
  }
}
