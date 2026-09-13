import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';

/// One observed mapping between a playback position and the byte offset the
/// player actually requested for it. Recorded when a seek/resume settles, so
/// the map reflects the real (often VBR) file layout instead of an average
/// bitrate estimate.
class TimeBytePoint {
  const TimeBytePoint({required this.positionMs, required this.byteOffset});
  final int positionMs;
  final int byteOffset;

  Map<String, dynamic> toJson() => {'t': positionMs, 'b': byteOffset};

  factory TimeBytePoint.fromJson(Map<String, dynamic> json) => TimeBytePoint(
    positionMs: (json['t'] as num?)?.toInt() ?? 0,
    byteOffset: (json['b'] as num?)?.toInt() ?? 0,
  );
}

/// Maps [positionMs] to a byte offset using observed seek anchors.
///
/// Interpolates between bracketing anchors and extrapolates a bounded
/// distance past the last one (resume positions usually sit just beyond the
/// last recorded anchor). Returns null when the estimate would be unreliable;
/// callers then fall back to [resumeByteOffset].
int? observedByteForTime(
  List<TimeBytePoint> points, {
  required int positionMs,
  required int fileSize,
}) {
  if (points.isEmpty || fileSize <= 0 || positionMs < 0) return null;
  final anchors =
      points.where((p) => p.positionMs > 0 && p.byteOffset > 0).toList()
        ..sort((a, b) => a.positionMs.compareTo(b.positionMs));
  if (anchors.isEmpty) return null;

  int? beforeIndex;
  int? afterIndex;
  for (var i = 0; i < anchors.length; i++) {
    if (anchors[i].positionMs <= positionMs) beforeIndex = i;
    if (anchors[i].positionMs >= positionMs) {
      afterIndex = i;
      break;
    }
  }
  // VBR can bend hard over long spans; never extrapolate more than 5% of the
  // file past the observed data.
  final maxExtra = (fileSize * 0.05).round();

  if (beforeIndex != null && afterIndex != null) {
    final before = anchors[beforeIndex];
    final after = anchors[afterIndex];
    if (before.positionMs == positionMs) {
      return before.byteOffset.clamp(0, fileSize);
    }
    final span = after.positionMs - before.positionMs;
    if (span <= 0 || after.byteOffset <= before.byteOffset) return null;
    final fraction = (positionMs - before.positionMs) / span;
    final value =
        before.byteOffset + (after.byteOffset - before.byteOffset) * fraction;
    return value.round().clamp(0, fileSize);
  }

  if (beforeIndex != null) {
    // Past the last anchor: extend with the nearest segment's slope.
    if (beforeIndex < 1) return null;
    final a = anchors[beforeIndex - 1];
    final b = anchors[beforeIndex];
    if (b.positionMs <= a.positionMs || b.byteOffset <= a.byteOffset) {
      return null;
    }
    final slope = (b.byteOffset - a.byteOffset) / (b.positionMs - a.positionMs);
    final extra = slope * (positionMs - b.positionMs);
    if (extra > maxExtra) return null;
    return (b.byteOffset + extra).round().clamp(0, fileSize);
  }

  // Before the first anchor: extend backwards with the first segment.
  if (afterIndex != null && afterIndex + 1 < anchors.length) {
    final a = anchors[afterIndex];
    final b = anchors[afterIndex + 1];
    if (b.positionMs <= a.positionMs || b.byteOffset <= a.byteOffset) {
      return null;
    }
    final slope = (b.byteOffset - a.byteOffset) / (b.positionMs - a.positionMs);
    final back = slope * (positionMs - a.positionMs);
    if (-back > maxExtra) return null;
    return (a.byteOffset + back).round().clamp(0, fileSize);
  }
  return null;
}

/// Merges a new observation into [existing], keeping a bounded, evenly
/// spread set. Nearby observations (within [minGapMs] of time or 1% of the
/// file size in bytes) replace the older point.
List<TimeBytePoint> mergeTimeBytePoint(
  List<TimeBytePoint> existing,
  TimeBytePoint point, {
  required int fileSize,
  int maxPoints = 24,
  int minGapMs = 60000,
}) {
  if (point.positionMs <= 0 || point.byteOffset <= 0 || fileSize <= 0) {
    return existing;
  }
  final byteGap = (fileSize * 0.01).round();
  final next = <TimeBytePoint>[];
  var replaced = false;
  for (final p in existing) {
    final near =
        (p.positionMs - point.positionMs).abs() <= minGapMs ||
        (p.byteOffset - point.byteOffset).abs() <= byteGap;
    if (near) {
      if (!replaced) {
        next.add(point);
        replaced = true;
      }
      continue;
    }
    next.add(p);
  }
  if (!replaced) next.add(point);
  next.sort((a, b) => a.positionMs.compareTo(b.positionMs));

  // Decimate the densest pair until the cap is met, so coverage stays spread.
  while (next.length > maxPoints) {
    var densest = 0;
    var smallestGap = 1 << 62;
    for (var i = 0; i < next.length - 1; i++) {
      final gap = next[i + 1].positionMs - next[i].positionMs;
      if (gap < smallestGap) {
        smallestGap = gap;
        densest = i;
      }
    }
    next.removeAt(densest);
  }
  return List.unmodifiable(next);
}

/// Local media bitrate (bytes/s) implied by the anchors bracketing
/// [positionMs], falling back to the file-average bitrate when the map is
/// too sparse to interpolate. Used to size the adaptive prefetch window.
int observedBitrateBps(
  List<TimeBytePoint> points, {
  required int positionMs,
  required int durationMs,
  required int fileSize,
}) {
  if (fileSize <= 0 || durationMs <= 0) return 0;
  final average = (fileSize * 1000 / durationMs).round();
  final anchors =
      points.where((p) => p.positionMs > 0 && p.byteOffset > 0).toList()
        ..sort((a, b) => a.positionMs.compareTo(b.positionMs));
  for (var i = 0; i < anchors.length - 1; i++) {
    final a = anchors[i];
    final b = anchors[i + 1];
    if (a.positionMs <= positionMs &&
        positionMs <= b.positionMs &&
        b.positionMs > a.positionMs &&
        b.byteOffset > a.byteOffset) {
      final rate =
          (b.byteOffset - a.byteOffset) * 1000 / (b.positionMs - a.positionMs);
      return rate.round();
    }
  }
  return average;
}

class PlaybackCacheEntry {
  const PlaybackCacheEntry({
    required this.cacheKey,
    required this.source,
    required this.file,
    required this.filePath,
    required this.complete,
    required this.byteSize,
    required this.lastUsedAt,
    this.timeBytePoints = const [],
  });

  final String cacheKey;
  final TorrentSource source;
  final TorrentFileEntry file;
  final String filePath;
  final bool complete;
  final int byteSize;
  final DateTime lastUsedAt;

  /// Observed (playback position → byte offset) anchors for this file.
  final List<TimeBytePoint> timeBytePoints;

  bool matchesWatchEntry(WatchEntry entry) =>
      source.id == entry.sourceId &&
      source.content == entry.media &&
      source.seasonNumber == entry.season &&
      source.episodeNumber == entry.episode;

  PlaybackCacheEntry copyWith({
    bool? complete,
    int? byteSize,
    DateTime? lastUsedAt,
    List<TimeBytePoint>? timeBytePoints,
    String? filePath,
  }) => PlaybackCacheEntry(
    cacheKey: cacheKey,
    source: source,
    file: file,
    filePath: filePath ?? this.filePath,
    complete: complete ?? this.complete,
    byteSize: byteSize ?? this.byteSize,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    timeBytePoints: timeBytePoints ?? this.timeBytePoints,
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
    'timeBytePoints': [for (final p in timeBytePoints) p.toJson()],
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
      timeBytePoints: [
        if (json['timeBytePoints'] is List)
          for (final raw in (json['timeBytePoints'] as List))
            if (raw is Map)
              TimeBytePoint.fromJson(Map<String, dynamic>.from(raw)),
      ],
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
