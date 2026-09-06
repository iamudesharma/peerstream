import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import 'bundled_torrent_api.dart';

abstract interface class TorrentProvider {
  String get name;
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
  });
}

class WebTorrentLegalDemoProvider implements TorrentProvider {
  const WebTorrentLegalDemoProvider({
    this.api = const BundledLegalTorrentApi(),
  });

  final BundledLegalTorrentApi api;

  @override
  String get name => 'WebTorrent Free Torrents';

  @override
  Future<List<TorrentSource>> findSources(
    MediaRef content, {
    int? seasonNumber,
    int? episodeNumber,
  }) async {
    return api.findByContent(
      content,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );
  }
}
