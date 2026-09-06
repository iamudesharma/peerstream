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
  return sha256
      .convert(
        utf8.encode('${source.inputType.name}|${source.uri}|${source.id}'),
      )
      .toString();
}
