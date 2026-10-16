import 'provider_catalog.dart';

import 'dart:convert';
import 'dart:io';

import '../storage/app_storage.dart';

Future<File> _file() async {
  final directory = Directory(await appStorage.dataDirectoryPath());
  await directory.create(recursive: true);
  return File('${directory.path}/peerstream-addons.json');
}

Future<List<String>> readAddonUrls() async {
  final file = await _file();
  if (!await file.exists()) return defaultAddonUrls;
  return (jsonDecode(await file.readAsString()) as List).cast<String>();
}

Future<void> writeAddonUrls(List<String> urls) async {
  final file = await _file();
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(jsonEncode(urls), flush: true);
  await temp.rename(file.path);
}
