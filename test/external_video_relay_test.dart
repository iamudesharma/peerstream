import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/video/external_video_relay_io.dart';

void main() {
  test(
    'forwards GET, HEAD and Range with addon headers and an opaque URL',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final relay = ExternalVideoRelay();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await relay.close();
        await upstream.close(force: true);
      });
      final seen = <String>[];
      upstream.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture-only');
        seen.add(request.method);
        final range = request.headers.value('range');
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.set('accept-ranges', 'bytes');
        if (range != null) {
          expect(range, 'bytes=2-4');
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 2-4/6');
          request.response.contentLength = 3;
          if (request.method != 'HEAD') request.response.write('cde');
        } else {
          request.response.contentLength = 6;
          if (request.method != 'HEAD') request.response.write('abcdef');
        }
        await request.response.close();
      });
      final url = await relay.start(
        Uri.parse(
          'http://127.0.0.1:${upstream.port}/private.mp4?credential=fixture',
        ),
        {'Authorization': 'Bearer fixture-only'},
      );
      expect(url.host, '127.0.0.1');
      expect(url.toString(), isNot(contains('credential')));
      final request = await client.getUrl(url);
      request.headers.set('range', 'bytes=2-4');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 2-4/6');
      expect(await utf8.decodeStream(response), 'cde');
      final head = await (await client.openUrl('HEAD', url)).close();
      expect(head.contentLength, 6);
      expect(await head.fold<int>(0, (n, data) => n + data.length), 0);
      expect(seen, ['GET', 'HEAD']);
      final forbidden = await (await client.getUrl(url.replace(path: '/wrong')))
          .close();
      expect(forbidden.statusCode, 403);
      await forbidden.drain<void>();
      final browser = await client.getUrl(url);
      browser.headers.set('origin', 'https://example.invalid');
      final blocked = await browser.close();
      expect(blocked.statusCode, 403);
      await blocked.drain<void>();
      await relay.close();
      await expectLater(
        () async => (await client.getUrl(url)).close(),
        throwsA(anything),
      );
    },
  );
}
