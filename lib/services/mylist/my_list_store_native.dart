import 'dart:convert';
import 'dart:io';

import '../storage/app_storage_native.dart';

import '../../models/saved_item.dart';

Future<File> _file(AppStorage storage) async {
  final directory = Directory(await storage.dataDirectoryPath());
  await directory.create(recursive: true);
  return File('${directory.path}/peerstream-my-list.json');
}

Future<List<SavedItem>> readMyList({AppStorage? storage}) async {
  final file = await _file(storage ?? appStorage);
  if (!await file.exists()) return const [];
  final raw = jsonDecode(await file.readAsString());
  if (raw is! List) {
    throw const FormatException(
      'Saved list is invalid; existing data was preserved.',
    );
  }
  final items = <SavedItem>[];
  for (final entry in raw) {
    if (entry is Map<String, dynamic>) {
      try {
        items.add(SavedItem.fromJson(entry));
      } catch (_) {}
    }
  }
  return normalizeMyList(items);
}

Future<void> writeMyList(List<SavedItem> items, {AppStorage? storage}) async {
  final normalized = normalizeMyList(items);
  final file = await _file(storage ?? appStorage);
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(
    jsonEncode(normalized.map((item) => item.toJson()).toList()),
    flush: true,
  );
  await temp.rename(file.path);
}
