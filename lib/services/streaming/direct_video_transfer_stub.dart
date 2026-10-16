class DirectVideoTransfer {
  Future<int> download(
    Uri uri,
    String path, {
    required int maxBytes,
    Map<String, String> headers = const {},
    required void Function(int, int) progress,
  }) async =>
      throw UnsupportedError('Video downloads are unavailable on the web.');
  Future<void> cancel() async {}
}
