import 'settings_values_shared.dart';

Future<Map<String, dynamic>> readSettingsValues() => readLegacySettingsValues();
Future<void> writeSettingsValues(Map<String, dynamic> values) =>
    writeLegacySettingsValues(values);
