import 'dart:convert';
import 'dart:io';

import '../storage/app_storage.dart';
import 'settings_values_shared.dart';

Future<void> _writes = Future.value();

Future<Map<String, dynamic>> readSettingsValues() async {
  await _writes;
  if (!await appStorage.hasCustomRoot()) return readLegacySettingsValues();
  final file = File(
    '${await appStorage.dataDirectoryPath()}/peerstream-settings.json',
  );
  if (await file.exists()) {
    return Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
  }
  final values = await readLegacySettingsValues();
  await writeSettingsValues(values);
  return values;
}

Future<void> writeSettingsValues(Map<String, dynamic> values) {
  final next = _writes.then((_) => _write(values));
  _writes = next.then<void>((_) {}, onError: (_, _) {});
  return next;
}

Future<void> _write(Map<String, dynamic> values) async {
  if (!await appStorage.hasCustomRoot()) {
    return writeLegacySettingsValues(values);
  }
  final file = File(
    '${await appStorage.dataDirectoryPath()}/peerstream-settings.json',
  );
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(values), flush: true);
  await temporary.rename(file.path);
  await removeLegacySettingsValues();
}
