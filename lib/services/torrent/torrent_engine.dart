import '../../models/torrent_models.dart';

abstract interface class TorrentEngine {
  bool get isSupported;
  String? get unsupportedReason;
  Future<void> initialize();
  Future<TorrentHandle> add(TorrentSource source);
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle);
  Stream<TorrentStats> watch(TorrentHandle handle);
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  );

  /// Stops a playback session. Cached bytes are retained unless the caller
  /// explicitly asks to delete them.
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false});
  Future<void> dispose();
}

TorrentFileEntry selectVideoFile(List<TorrentFileEntry> files, {String? hint}) {
  final videos = files.where((file) {
    final lower = file.name.toLowerCase();
    const extensions = ['.mp4', '.m4v', '.mkv', '.webm', '.avi', '.mov'];
    return file.isStreamable &&
        extensions.any(lower.endsWith) &&
        !lower.contains('sample') &&
        !lower.contains('trailer');
  }).toList();
  if (videos.isEmpty) throw StateError('This torrent has no streamable video.');
  final normalizedHint = hint?.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  if (normalizedHint != null && normalizedHint.isNotEmpty) {
    final matches = videos.where((file) {
      final normalizedName = file.name.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      return normalizedName.contains(normalizedHint);
    }).toList();
    if (matches.isNotEmpty) {
      matches.sort((a, b) => b.size.compareTo(a.size));
      return matches.first;
    }
  }
  videos.sort((a, b) => b.size.compareTo(a.size));
  return videos.first;
}
