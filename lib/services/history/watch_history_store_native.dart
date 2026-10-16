import 'dart:convert';
import 'dart:io';

import '../storage/app_storage_native.dart';

import '../../models/watch_progress.dart';

Future<File> _file(AppStorage storage) async {
  final directory = Directory(await storage.dataDirectoryPath());
  await directory.create(recursive: true);
  return File('${directory.path}/peerstream-watch-history.json');
}

Future<List<WatchEntry>> readWatchHistory({AppStorage? storage}) async {
  final file = await _file(storage ?? appStorage);
  if (!await file.exists()) return const [];
  final raw = jsonDecode(await file.readAsString());
  if (raw is! List) {
    throw const FormatException(
      'Saved list is invalid; existing data was preserved.',
    );
  }
  final entries = <WatchEntry>[];
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      try {
        entries.add(WatchEntry.fromJson(item));
      } catch (_) {}
    }
  }
  return normalizeWatchHistory(entries);
}

Future<void> writeWatchHistory(
  List<WatchEntry> entries, {
  AppStorage? storage,
}) async {
  final normalized = normalizeWatchHistory(entries);
  final file = await _file(storage ?? appStorage);
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(
    jsonEncode(normalized.map((entry) => entry.toJson()).toList()),
    flush: true,
  );
  await temp.rename(file.path);
}
