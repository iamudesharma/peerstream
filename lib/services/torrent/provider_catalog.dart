import '../../models/torrent_models.dart';

/// Provider keys advertised by Torrentio's current public configuration.
/// The remaining legacy keys have no verified adapter in this application.
const supportedIndexers = <String, String>{
  'yts': 'YTS',
  'eztv': 'EZTV',
  'piratebay': 'ThePirateBay',
  'tgx': 'TorrentGalaxy',
  'rarbg': 'RARBG',
  'nyaasi': 'NyaaSi',
  'kickass': 'KickassTorrents',
  'magnetdl': 'MagnetDL',
  '1337x': '1337x',
};
const unavailableIndexers = [
  'torlock',
  'ettv',
  'zooqle',
  'bitsearch',
  'glodls',
  'limetorrent',
  'torrentfunk',
  'torrentproject',
];
const defaultAddonUrls = ['https://torrentio.strem.fun/manifest.json'];

/// Splits one provider's allowed sources into per-lane groups for the tab UI.
///
/// Torrentio aggregates many indexers (YTS, EZTV, 1337x, ThePirateBay, …)
/// behind a single addon host; without this split they collapse into one
/// tab and the individual sources the user asked about stay invisible.
/// Each indexer with at least one source gets its own lane named by the
/// indexer's display name. Every other provider passes through untouched as
/// a single lane. Pure for testability; callers rank before/after.
List<({String name, List<TorrentSource> sources})> splitIndexerLanes(
  String providerName,
  List<TorrentSource> allowed,
) {
  if (providerName != 'torrentio.strem.fun') {
    return [(name: providerName, sources: allowed)];
  }
  final names = <String>{
    ...supportedIndexers.values,
    ...allowed.map((s) => s.providerName),
  };
  return [
    for (final name in names)
      if (allowed.any((s) => s.providerName == name))
        (
          name: name,
          sources: allowed.where((s) => s.providerName == name).toList(),
        ),
  ];
}
