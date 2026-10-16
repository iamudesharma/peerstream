class ExternalVideoRelay {
  Future<Uri> start(Uri uri, Map<String, String> headers) async =>
      throw UnsupportedError('External playback is unavailable on the web.');
  Future<void> close() async {}
}
