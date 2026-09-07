import 'dart:io';

import '../../models/torrent_models.dart';

/// Playability ranking: platform compatibility and observed reliability
/// first, then quality and swarm health. Seed counts alone are insufficient.
///
/// Ordering (lower is better):
/// 1. Direct HTTP(S) playable everywhere, including web — always first.
/// 2. Exact file selection (fileIndex or fileNameHint) — avoids wrong-file
///    playback inside multi-file torrents.
/// 3. Platform compatibility (extension allow-list per OS).
/// 4. Swarm health: seeds, then peers.
/// 5. Quality preference: 1080p > 720p > 4K (4K stalls thin swarms) > rest.
/// 6. Smaller size wins ties (less to buffer before first frame).
int compareRankedSources(TorrentSource a, TorrentSource b) {
  final aDirect = a.inputType == TorrentInputType.directUrl ? 0 : 1;
  final bDirect = b.inputType == TorrentInputType.directUrl ? 0 : 1;
  if (aDirect != bDirect) return aDirect.compareTo(bDirect);

  final aExact = (a.fileIndex != null || a.fileNameHint != null) ? 0 : 1;
  final bExact = (b.fileIndex != null || b.fileNameHint != null) ? 0 : 1;
  if (aExact != bExact) return aExact.compareTo(bExact);

  final aCompat = _compatibilityPenalty(a);
  final bCompat = _compatibilityPenalty(b);
  if (aCompat != bCompat) return aCompat.compareTo(bCompat);

  final seedsCmp = (b.seeds ?? -1).compareTo(a.seeds ?? -1);
  if (seedsCmp != 0) return seedsCmp;
  final peersCmp = (b.peers ?? -1).compareTo(a.peers ?? -1);
  if (peersCmp != 0) return peersCmp;

  final qCmp = _qualityRank(a.name).compareTo(_qualityRank(b.name));
  if (qCmp != 0) return qCmp;

  return (a.sizeBytes ?? 1 << 62).compareTo(b.sizeBytes ?? 1 << 62);
}

/// Sorts in place using [compareRankedSources] and returns the list.
List<TorrentSource> rankSources(List<TorrentSource> sources) {
  sources.sort(compareRankedSources);
  return sources;
}

/// Refresh an expired route-provided source against fresh discovery results.
///
/// Prefers the same source id (stable across re-query), then the same
/// provider with compatible quality, then the globally best ranked source.
/// Returns null when no playable alternative exists.
TorrentSource? refreshSource(
  TorrentSource old,
  List<TorrentSource> fresh,
) {
  if (fresh.isEmpty) return null;
  for (final s in fresh) {
    if (s.id == old.id) return s;
  }
  final sameProvider = fresh
      .where((s) => s.providerName == old.providerName)
      .toList();
  if (sameProvider.isNotEmpty) {
    rankSources(sameProvider);
    return sameProvider.first;
  }
  final ranked = List<TorrentSource>.of(fresh);
  rankSources(ranked);
  return ranked.first;
}

int _compatibilityPenalty(TorrentSource s) {
  final name = (s.fileNameHint ?? s.name).toLowerCase();
  // iOS/tvOS cannot handle some containers; prefer mp4/m4v there.
  if (Platform.isIOS || Platform.isMacOS) {
    if (name.contains('.mp4') || name.contains('.m4v')) return 0;
    if (name.contains('.mkv')) return 1;
    return 0;
  }
  if (name.contains('.mkv') || name.contains('.mp4')) return 0;
  if (name.contains('.webm') || name.contains('.avi')) return 1;
  return 2;
}

int _qualityRank(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('1080p')) return 0;
  if (lower.contains('720p')) return 1;
  if (lower.contains('2160p') || lower.contains('4k')) return 2;
  if (lower.contains('480p')) return 3;
  return 4;
}
