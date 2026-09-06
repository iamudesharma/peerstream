import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class SubtitleFileStore {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  Future<String> importFile(String path, {String? name}) async {
    final source = File(path);
    if (!await source.exists()) {
      throw const FileSystemException('Subtitle file is unavailable.');
    }
    final target = await _target(name ?? source.uri.pathSegments.last);
    await source.copy(target.path);
    return target.path;
  }

  Future<String> download(Uri uri, {required String name}) async {
    final target = await _target(name);
    await _dio.downloadUri(uri, target.path);
    if (!await target.exists() || await target.length() == 0) {
      throw const FileSystemException('Subtitle download was empty.');
    }
    return target.path;
  }

  Future<File> _target(String name) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}subtitles',
    );
    await directory.create(recursive: true);
    final safe = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(
      '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}_$safe',
    );
  }
}
