import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/torrent_models.dart';

/// A stable, filesystem-safe identity for data stored for a torrent source.
///
/// Magnets use their info hash so tracker ordering does not create duplicate
/// cache entries. Torrent URLs fall back to the source URI and source id.
String torrentCacheKey(TorrentSource source) {
  if (source.inputType == TorrentInputType.magnet) {
    final infoHash = (source.uri.queryParametersAll['xt'] ?? const [])
        .map((value) => value.toLowerCase())
        .where((value) => value.startsWith('urn:btih:'))
        .map((value) => value.substring('urn:btih:'.length))
        .firstOrNull;
    if (infoHash != null && RegExp(r'^[a-z0-9]{32,64}$').hasMatch(infoHash)) {
      return infoHash;
    }
  }
  if (source.inputType == TorrentInputType.directUrl) {
    // A shared HTTP endpoint can serve different videos for different addon
    // credentials or episodes. Never replay a save from another request.
    final headers =
        source.headers.entries
            .map((entry) => [entry.key.toLowerCase(), entry.value])
            .toList()
          ..sort((a, b) {
            final key = a[0].compareTo(b[0]);
            return key != 0 ? key : a[1].compareTo(b[1]);
          });
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              source.inputType.name,
              source.uri.toString(),
              source.id,
              source.content.routeKey,
              source.seasonNumber,
              source.episodeNumber,
              headers,
            ]),
          ),
        )
        .toString();
  }
  return sha256
      .convert(
        utf8.encode('${source.inputType.name}|${source.uri}|${source.id}'),
      )
      .toString();
}
