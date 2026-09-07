import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'provider_catalog.dart';

List<String> _urls = defaultAddonUrls;
bool _webLoaded = false;

Future<List<String>> readAddonUrls() async {
  if (kIsWeb && !_webLoaded) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList('peerstream-addon-urls');
      if (stored != null && stored.isNotEmpty) _urls = stored;
    } catch (_) {}
    _webLoaded = true;
  }
  return List.of(_urls);
}

Future<void> writeAddonUrls(List<String> urls) async {
  _urls = urls;
  if (kIsWeb) {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('peerstream-addon-urls', urls);
    } catch (_) {}
  }
}
