import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/watch_progress.dart';

List<WatchEntry> _entries = const [];
bool _webLoaded = false;

Future<List<WatchEntry>> readWatchHistory() async {
  if (kIsWeb && !_webLoaded) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('peerstream-watch-history');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final loaded = <WatchEntry>[];
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              try {
                loaded.add(WatchEntry.fromJson(item));
              } catch (_) {}
            }
          }
          _entries = normalizeWatchHistory(loaded);
        }
      }
    } catch (_) {}
    _webLoaded = true;
  }
  return List.of(_entries);
}

Future<void> writeWatchHistory(List<WatchEntry> entries) async {
  _entries = normalizeWatchHistory(entries);
  if (kIsWeb) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'peerstream-watch-history',
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
