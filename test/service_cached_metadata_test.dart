import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/models/media_item.dart';
import 'package:peerstream/models/torrent_models.dart';
import 'package:peerstream/services/local_service/service_client.dart';
import 'package:peerstream/services/local_service/service_torrent_engine.dart';

class _Client extends LocalServiceClient {
  _Client(this.cachedResult, {this.supportsCachedMetadata = true})
    : super(executable: '', library: '', root: '') {
    instance = 'fixture';
  }
  final Object? cachedResult;
  final bool supportsCachedMetadata;
  final adds = <Map<String, dynamic>>[];
  @override
  Future<void> start({bool restart = false}) async {}
  @override
  Future<Map<String, dynamic>> health() async => {
    'bridgeVersion': 'fixture',
    'capabilities': {'cachedMetadataResume': supportsCachedMetadata},
  };
  @override
  Future<dynamic> command(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (op == 'add') {
      adds.add(Map.of(args));
      if (args['resumeOnly'] == true && cachedResult != null) {
        throw cachedResult!;
      }
      return {'session': 'remote'};
    }
    return <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
}

void main() {
  for (final mode in ['cached', 'miss', 'timeout', 'storage', 'legacy']) {
    test(
      'metadata fetch happens only after explicit cache miss: $mode',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var fetches = 0;
        server.listen((request) async {
          fetches++;
          request.response.add([1, 2, 3]);
          await request.response.close();
        });
        final error = switch (mode) {
          'miss' => ServiceCommandException(
            'miss',
            statusCode: 422,
            code: 'cache_miss',
          ),
          'timeout' => TimeoutException('ambiguous add'),
          'storage' => ServiceCommandException(
            'drive unavailable',
            statusCode: 422,
            code: 'command_failed',
          ),
          _ => null,
        };
        final client = _Client(error, supportsCachedMetadata: mode != 'legacy');
        final engine = ServiceTorrentEngine(client);
        final source = TorrentSource(
          id: 'original',
          content: const MediaRef(id: -90909, type: MediaType.movie),
          name: 'Original fixture',
          uri: Uri.parse('http://127.0.0.1:${server.port}/video.torrent'),
          inputType: TorrentInputType.torrentUrl,
          providerName: 'Original generated fixture',
          attribution: 'Original fixture',
          license: 'CC0',
          provenanceUrl: Uri.parse('about:blank'),
        );
        try {
          if (mode == 'timeout' || mode == 'storage') {
            await expectLater(engine.add(source), throwsA(same(error)));
          } else {
            await engine.add(source);
          }
          expect(fetches, mode == 'miss' || mode == 'legacy' ? 1 : 0);
          expect(client.adds.length, mode == 'miss' ? 2 : 1);
          expect(
            client.adds.first['resumeOnly'],
            mode == 'legacy' ? isNull : isTrue,
          );
          if (mode == 'miss') {
            expect(client.adds.last['torrent'], [1, 2, 3]);
            expect(
              client.adds.last['requestId'],
              client.adds.first['requestId'],
            );
          }
        } finally {
          await engine.dispose();
          await client.snapshots.close();
          await server.close(force: true);
        }
      },
    );
  }
}
