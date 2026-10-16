import 'package:shared_preferences/shared_preferences.dart';

Future<Map<String, dynamic>> readLegacySettingsValues() async {
  final prefs = await SharedPreferences.getInstance();
  return {
    for (final key in prefs.getKeys().where(
      (key) => key.startsWith('settings.'),
    ))
      key: prefs.get(key),
  };
}

Future<void> writeLegacySettingsValues(Map<String, dynamic> values) async {
  final prefs = await SharedPreferences.getInstance();
  for (final entry in values.entries) {
    final value = entry.value;
    if (value == null) {
      await prefs.remove(entry.key);
    } else if (value is bool) {
      await prefs.setBool(entry.key, value);
    } else if (value is double) {
      await prefs.setDouble(entry.key, value);
    } else if (value is String) {
      await prefs.setString(entry.key, value);
    }
  }
}

Future<void> removeLegacySettingsValues() async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in prefs.getKeys().where(
    (key) => key.startsWith('settings.'),
  )) {
    await prefs.remove(key);
  }
}
