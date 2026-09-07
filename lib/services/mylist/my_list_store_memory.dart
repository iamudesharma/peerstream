import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/saved_item.dart';

List<SavedItem> _items = const [];
bool _webLoaded = false;

Future<List<SavedItem>> readMyList() async {
  if (kIsWeb && !_webLoaded) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('peerstream-my-list');
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final loaded = <SavedItem>[];
          for (final entry in decoded) {
            if (entry is Map<String, dynamic>) {
              try {
                loaded.add(SavedItem.fromJson(entry));
              } catch (_) {}
            }
          }
          _items = normalizeMyList(loaded);
        }
      }
    } catch (_) {}
    _webLoaded = true;
  }
  return List.of(_items);
}

Future<void> writeMyList(List<SavedItem> items) async {
  _items = normalizeMyList(items);
  if (kIsWeb) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'peerstream-my-list',
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
