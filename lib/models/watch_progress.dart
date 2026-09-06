import 'media_item.dart';

const watchHistoryMaxEntries = 50;
const watchFinishedProgress = 0.95;
const watchFinishedTailMs = 30000;
const watchTrivialPositionMs = 30000;
const watchTrivialProgress = 0.05;

String watchKey(MediaRef media, int? season, int? episode) {
  if (media.type == MediaType.tv && season != null && episode != null) {
    return '${media.type.name}/${media.id}/$season/$episode';
  }
  return '${media.type.name}/${media.id}';
}

String formatWatchTimestamp(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = value.inHours;
  final minutes = value.inMinutes % 60;
  final seconds = value.inSeconds % 60;
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '$minutes:${two(seconds)}';
}

class WatchEntry {
  const WatchEntry({
    required this.key,
    required this.media,
    required this.title,
    this.posterPath,
    this.backdropPath,
    this.season,
    this.episode,
    required this.sourceId,
    required this.providerName,
    required this.sourceUri,
    required this.inputType,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final String key;
  final MediaRef media;
  final String title;
  final String? posterPath;
  final String? backdropPath;
  final int? season;
  final int? episode;
  final String sourceId;
  final String providerName;
  final String sourceUri;
  final String inputType;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;

  double get progress {
    if (durationMs <= 0 || positionMs <= 0) return 0;
    return positionMs / durationMs;
  }

  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);
  Duration get remaining => duration - position;

  bool get isFinished {
    if (durationMs <= 0) return false;
    if (progress >= watchFinishedProgress) return true;
    return durationMs - positionMs <= watchFinishedTailMs;
  }

  bool get isTrivial {
    return positionMs < watchTrivialPositionMs &&
        progress < watchTrivialProgress;
  }

  bool get isResumable =>
      positionMs > 0 && !isFinished && !isTrivial;

  String remainingLabel() {
    final left = remaining;
    if (left <= Duration.zero) return 'Finished';
    if (left < const Duration(minutes: 1)) {
      return '${left.inSeconds}s left';
    }
    if (left < const Duration(hours: 1)) {
      return '${left.inMinutes} min left';
    }
    final hours = left.inHours;
    final minutes = left.inMinutes % 60;
    if (minutes == 0) return '${hours}h left';
    return '${hours}h ${minutes}m left';
  }

  WatchEntry copyWith({
    String? key,
    MediaRef? media,
    String? title,
    String? posterPath,
    String? backdropPath,
    int? season,
    int? episode,
    String? sourceId,
    String? providerName,
    String? sourceUri,
    String? inputType,
    int? positionMs,
    int? durationMs,
    DateTime? updatedAt,
  }) {
    return WatchEntry(
      key: key ?? this.key,
      media: media ?? this.media,
      title: title ?? this.title,
      posterPath: posterPath ?? this.posterPath,
      backdropPath: backdropPath ?? this.backdropPath,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      sourceId: sourceId ?? this.sourceId,
      providerName: providerName ?? this.providerName,
      sourceUri: sourceUri ?? this.sourceUri,
      inputType: inputType ?? this.inputType,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'mediaId': media.id,
    'mediaType': media.type.name,
    'title': title,
    'posterPath': posterPath,
    'backdropPath': backdropPath,
    'season': season,
    'episode': episode,
    'sourceId': sourceId,
    'providerName': providerName,
    'sourceUri': sourceUri,
    'inputType': inputType,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  factory WatchEntry.fromJson(Map<String, dynamic> json) {
    final id = json['mediaId'];
    if (id is! int) throw const FormatException('Invalid watch entry.');
    final key = json['key'] as String?;
    final type = MediaType.parse(json['mediaType'] as String? ?? 'movie');
    final media = MediaRef(id: id, type: type);
    final season = json['season'] as int?;
    final episode = json['episode'] as int?;
    final updatedAt = json['updatedAt'];
    return WatchEntry(
      key: key ?? watchKey(media, season, episode),
      media: media,
      title: (json['title'] as String?) ?? 'Untitled',
      posterPath: json['posterPath'] as String?,
      backdropPath: json['backdropPath'] as String?,
      season: season,
      episode: episode,
      sourceId: (json['sourceId'] as String?) ?? '',
      providerName: (json['providerName'] as String?) ?? '',
      sourceUri: (json['sourceUri'] as String?) ?? '',
      inputType: (json['inputType'] as String?) ?? '',
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      updatedAt: updatedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(updatedAt)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WatchEntry &&
        other.key == key &&
        other.media == media &&
        other.title == title &&
        other.posterPath == posterPath &&
        other.backdropPath == backdropPath &&
        other.season == season &&
        other.episode == episode &&
        other.sourceId == sourceId &&
        other.providerName == providerName &&
        other.sourceUri == sourceUri &&
        other.inputType == inputType &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    key,
    media,
    title,
    posterPath,
    backdropPath,
    season,
    episode,
    sourceId,
    providerName,
    sourceUri,
    inputType,
    positionMs,
    durationMs,
    updatedAt,
  );
}

List<WatchEntry> normalizeWatchHistory(List<WatchEntry> entries) {
  final latest = <String, WatchEntry>{};
  for (final entry in entries) {
    final existing = latest[entry.key];
    if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
      latest[entry.key] = entry;
    }
  }
  final visible = latest.values
      .where((entry) => !entry.isFinished && !entry.isTrivial)
      .toList();
  visible.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (visible.length > watchHistoryMaxEntries) {
    return visible.sublist(0, watchHistoryMaxEntries);
  }
  return visible;
}
