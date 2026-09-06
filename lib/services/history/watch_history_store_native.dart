import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/watch_progress.dart';

Future<File> _file() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return File('${directory.path}/peerstream-watch-history.json');
}

Future<List<WatchEntry>> readWatchHistory() async {
  try {
    final file = await _file();
    if (!await file.exists()) return const [];
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List) return const [];
    final entries = <WatchEntry>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        try {
          entries.add(WatchEntry.fromJson(item));
        } catch (_) {}
      }
    }
    return normalizeWatchHistory(entries);
  } catch (_) {
    return const [];
  }
}

Future<void> writeWatchHistory(List<WatchEntry> entries) async {
  try {
    final normalized = normalizeWatchHistory(entries);
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode(normalized.map((entry) => entry.toJson()).toList()),
      flush: true,
    );
    await temp.rename(file.path);
  } catch (_) {}
}
