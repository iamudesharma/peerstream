import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';

class PlaybackCacheEntry {
  const PlaybackCacheEntry({
    required this.cacheKey,
    required this.source,
    required this.file,
    required this.filePath,
    required this.complete,
    required this.byteSize,
    required this.lastUsedAt,
  });

  final String cacheKey;
  final TorrentSource source;
  final TorrentFileEntry file;
  final String filePath;
  final bool complete;
  final int byteSize;
  final DateTime lastUsedAt;

  bool matchesWatchEntry(WatchEntry entry) =>
      source.id == entry.sourceId &&
      source.content == entry.media &&
      source.seasonNumber == entry.season &&
      source.episodeNumber == entry.episode;

  PlaybackCacheEntry copyWith({
    bool? complete,
    int? byteSize,
    DateTime? lastUsedAt,
  }) => PlaybackCacheEntry(
    cacheKey: cacheKey,
    source: source,
    file: file,
    filePath: filePath,
    complete: complete ?? this.complete,
    byteSize: byteSize ?? this.byteSize,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  Map<String, dynamic> toJson() => {
    'cacheKey': cacheKey,
    'source': {
      'id': source.id,
      'mediaId': source.content.id,
      'mediaType': source.content.type.name,
      'name': source.name,
      'uri': source.uri.toString(),
      'inputType': source.inputType.name,
      'providerName': source.providerName,
      'attribution': source.attribution,
      'license': source.license,
      'provenanceUrl': source.provenanceUrl.toString(),
      'fileNameHint': source.fileNameHint,
      'fileIndex': source.fileIndex,
      'headers': source.headers,
      'seasonNumber': source.seasonNumber,
      'episodeNumber': source.episodeNumber,
    },
    'file': {
      'index': file.index,
      'name': file.name,
      'size': file.size,
      'isStreamable': file.isStreamable,
    },
    'filePath': filePath,
    'complete': complete,
    'byteSize': byteSize,
    'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
  };

  factory PlaybackCacheEntry.fromJson(Map<String, dynamic> json) {
    final rawSource = json['source'];
    final rawFile = json['file'];
    if (rawSource is! Map || rawFile is! Map) {
      throw const FormatException('Invalid playback cache entry.');
    }
    final source = Map<String, dynamic>.from(rawSource);
    final file = Map<String, dynamic>.from(rawFile);
    final input = TorrentInputType.values.byName(
      source['inputType'] as String? ?? TorrentInputType.magnet.name,
    );
    final headers = <String, String>{};
    if (source['headers'] is Map) {
      for (final item in (source['headers'] as Map).entries) {
        if (item.key is String && item.value is String) {
          headers[item.key as String] = item.value as String;
        }
      }
    }
    return PlaybackCacheEntry(
      cacheKey: json['cacheKey'] as String? ?? '',
      source: TorrentSource(
        id: source['id'] as String? ?? '',
        content: MediaRef(
          id: source['mediaId'] as int? ?? 0,
          type: MediaType.parse(source['mediaType'] as String? ?? 'movie'),
        ),
        name: source['name'] as String? ?? 'Cached source',
        uri: Uri.parse(source['uri'] as String? ?? ''),
        inputType: input,
        providerName: source['providerName'] as String? ?? '',
        attribution: source['attribution'] as String? ?? '',
        license: source['license'] as String? ?? '',
        provenanceUrl: Uri.parse(source['provenanceUrl'] as String? ?? ''),
        fileNameHint: source['fileNameHint'] as String?,
        fileIndex: (source['fileIndex'] as num?)?.toInt(),
        headers: headers,
        seasonNumber: (source['seasonNumber'] as num?)?.toInt(),
        episodeNumber: (source['episodeNumber'] as num?)?.toInt(),
      ),
      file: TorrentFileEntry(
        index: (file['index'] as num?)?.toInt() ?? 0,
        name: file['name'] as String? ?? '',
        size: (file['size'] as num?)?.toInt() ?? 0,
        isStreamable: file['isStreamable'] as bool? ?? false,
      ),
      filePath: json['filePath'] as String? ?? '',
      complete: json['complete'] as bool? ?? false,
      byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['lastUsedAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class PlaybackCacheSummary {
  const PlaybackCacheSummary({
    required this.byteSize,
    required this.maxBytes,
    required this.entries,
  });
  final int byteSize;
  final int maxBytes;
  final int entries;
}

class PlaybackPreferences {
  const PlaybackPreferences({
    required this.maxCacheBytes,
    this.preferredAudioLanguage,
    this.preferredSubtitleLanguage,
  });
  final int maxCacheBytes;
  final String? preferredAudioLanguage;
  final String? preferredSubtitleLanguage;

  PlaybackPreferences copyWith({
    int? maxCacheBytes,
    String? preferredAudioLanguage,
    String? preferredSubtitleLanguage,
  }) => PlaybackPreferences(
    maxCacheBytes: maxCacheBytes ?? this.maxCacheBytes,
    preferredAudioLanguage:
        preferredAudioLanguage ?? this.preferredAudioLanguage,
    preferredSubtitleLanguage:
        preferredSubtitleLanguage ?? this.preferredSubtitleLanguage,
  );
}
