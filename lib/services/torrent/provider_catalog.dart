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
