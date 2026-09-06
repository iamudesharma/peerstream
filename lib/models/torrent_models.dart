import 'media_item.dart';

enum TorrentInputType { magnet, torrentUrl, directUrl }

class TorrentSource {
  const TorrentSource({
    required this.id,
    required this.content,
    required this.name,
    required this.uri,
    required this.inputType,
    required this.providerName,
    required this.attribution,
    required this.license,
    required this.provenanceUrl,
    this.fileNameHint,
    this.fileIndex,
    this.seeds,
    this.peers,
    this.sizeBytes,
    this.description,
    this.headers = const {},
    this.seasonNumber,
    this.episodeNumber,
  });
  final String id;
  final MediaRef content;
  final String name;
  final Uri uri;
  final TorrentInputType inputType;
  final String providerName;
  final String attribution;
  final String license;
  final Uri provenanceUrl;
  final String? fileNameHint;
  final int? fileIndex;
  final int? seeds;
  final int? peers;
  final int? sizeBytes;
  final String? description;
  final Map<String, String> headers;
  final int? seasonNumber;
  final int? episodeNumber;
}

class TorrentHandle {
  const TorrentHandle(this.id);
  final String id;
}

class TorrentFileEntry {
  const TorrentFileEntry({
    required this.index,
    required this.name,
    required this.size,
    required this.isStreamable,
  });
  final int index;
  final String name;
  final int size;
  final bool isStreamable;
}

class TorrentPlaybackStream {
  const TorrentPlaybackStream({
    required this.id,
    required this.uri,
    required this.file,
    this.fromCache = false,
  });
  final String id;
  final Uri uri;
  final TorrentFileEntry file;

  /// True when a complete file is opened directly from this device.
  final bool fromCache;
}

class TorrentStats {
  const TorrentStats({
    this.name,
    this.phase = 'idle',
    this.progress = 0,
    this.bufferProgress = 0,
    this.downloadRate = 0,
    this.uploadRate = 0,
    this.peers,
    this.seeds,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
  });
  final String? name;
  final String phase;
  final double progress;
  final double bufferProgress;
  final int downloadRate;
  final int uploadRate;
  final int? peers;
  final int? seeds;
  final int downloadedBytes;
  final int totalBytes;
}
