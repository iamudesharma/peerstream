class SubtitleFileStore {
  Future<String> importFile(String path, {String? name}) async => path;
  Future<String> download(Uri uri, {required String name}) async =>
      uri.toString();
}
