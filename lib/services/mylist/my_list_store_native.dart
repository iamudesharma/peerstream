import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/saved_item.dart';

Future<File> _file() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return File('${directory.path}/peerstream-my-list.json');
}

Future<List<SavedItem>> readMyList() async {
  try {
    final file = await _file();
    if (!await file.exists()) return const [];
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List) return const [];
    final items = <SavedItem>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        try {
          items.add(SavedItem.fromJson(entry));
        } catch (_) {}
      }
    }
    return normalizeMyList(items);
  } catch (_) {
    return const [];
  }
}

Future<void> writeMyList(List<SavedItem> items) async {
  try {
    final normalized = normalizeMyList(items);
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode(normalized.map((item) => item.toJson()).toList()),
      flush: true,
    );
    await temp.rename(file.path);
  } catch (_) {}
}
