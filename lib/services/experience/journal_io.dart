import 'dart:convert';
import 'dart:io';

import '../storage/app_storage.dart';

Future<Map<String, dynamic>> readJournal() async {
  final file = File(
    '${await appStorage.dataDirectoryPath()}/peerstream-experience.json',
  );
  if (!await file.exists()) return {};
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('Experience data exceeds its size budget');
  }
  return Map<String, dynamic>.from(
    jsonDecode(await file.readAsString()) as Map,
  );
}

Future<void> writeJournal(Map<String, dynamic> data) async {
  final file = File(
    '${await appStorage.dataDirectoryPath()}/peerstream-experience.json',
  );
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(jsonEncode(data), flush: true);
  await temp.rename(file.path);
}
