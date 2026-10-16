import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/torrent/native_torrent_engine.dart';
import 'package:peerstream/services/torrent/torrent_engine.dart';

void main() {
  test(
    'supported native engine reports not started before a video opens',
    () async {
      final engine = NativeTorrentEngine();
      final server = await engine.httpServerInfo();
      expect(server.status, HttpServerStatus.notStarted);
      expect(server.url, isNull);
    },
  );
}
