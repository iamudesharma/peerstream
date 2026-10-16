import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:peerstream/services/streaming/direct_video_transfer_io.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late Uri uri;
  final payload = List.generate(64 * 1024, (i) => i % 251);
  setUp(() async {
    root = await (await Directory('.tmp').create(recursive: true))
        .createTemp('direct-download-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/video.mkv');
  });
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'streams the exact video with source headers and reports completion',
    () async {
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer fixture-only');
        request.response.headers.contentType = ContentType(
          'video',
          'x-matroska',
        );
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      var received = 0;
      final path = '${root.path}/video.mkv';
      final bytes = await DirectVideoTransfer().download(
        uri,
        path,
        maxBytes: payload.length,
        headers: {'Authorization': 'Bearer fixture-only'},
        progress: (n, _) => received = n,
      );
      expect(bytes, payload.length);
      expect(received, payload.length);
      expect(await File(path).readAsBytes(), payload);
      expect(await File('$path.download').exists(), isFalse);
    },
  );

  test('resumes only validated ranges without duplicating bytes', () async {
    final path = '${root.path}/video.mkv';
    await File('$path.download').writeAsBytes(payload.take(1024).toList());
    await File('$path.download.json').writeAsString(
      jsonEncode({'uri': uri.toString(), 'validator': '"original"'}),
    );
    server.listen((request) async {
      expect(request.headers.value('range'), 'bytes=1024-');
      expect(request.headers.value('if-range'), '"original"');
      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes 1024-${payload.length - 1}/${payload.length}',
      );
      request.response.headers.set('etag', '"original"');
      request.response.contentLength = payload.length - 1024;
      request.response.add(payload.sublist(1024));
      await request.response.close();
    });
    await DirectVideoTransfer().download(
      uri,
      path,
      maxBytes: payload.length,
      progress: (_, _) {},
    );
    expect(await File(path).readAsBytes(), payload);
  });

  test(
    'server ignoring Range restarts instead of appending old bytes',
    () async {
      final path = '${root.path}/video.mkv';
      await File('$path.download').writeAsBytes([9, 9, 9]);
      await File('$path.download.json').writeAsString(
        jsonEncode({'uri': uri.toString(), 'validator': '"old"'}),
      );
      server.listen((request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      await DirectVideoTransfer().download(
        uri,
        path,
        maxBytes: payload.length,
        progress: (_, _) {},
      );
      expect(await File(path).readAsBytes(), payload);
    },
  );

  test('wrong resume offset never produces a completed file', () async {
    final path = '${root.path}/video.mkv';
    await File('$path.download').writeAsBytes([1, 2, 3]);
    await File(
      '$path.download.json',
    ).writeAsString(jsonEncode({'uri': uri.toString(), 'validator': '"old"'}));
    server.listen((request) async {
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 0-5/6');
      request.response.add([1, 2, 3, 4, 5, 6]);
      await request.response.close();
    });
    await expectLater(
      DirectVideoTransfer().download(
        uri,
        path,
        maxBytes: 100,
        progress: (_, _) {},
      ),
      throwsStateError,
    );
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.download').readAsBytes(), [1, 2, 3]);
  });

  test(
    'storage budget rejects declared oversize before writing payload',
    () async {
      server.listen((request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      final path = '${root.path}/video.mkv';
      await expectLater(
        DirectVideoTransfer().download(
          uri,
          path,
          maxBytes: 100,
          progress: (_, _) {},
        ),
        throwsStateError,
      );
      expect(await File(path).exists(), isFalse);
      expect(await File('$path.download').exists(), isFalse);
    },
  );

  test('cancel drains file writes and leaves no completed video', () async {
    final sent = Completer<void>();
    server.listen((request) async {
      request.response.contentLength = payload.length * 2;
      request.response.add(payload);
      await request.response.flush();
      sent.complete();
    });
    final transfer = DirectVideoTransfer();
    final path = '${root.path}/video.mkv';
    final result = transfer.download(
      uri,
      path,
      maxBytes: payload.length * 2,
      progress: (_, _) {},
    );
    final failed = expectLater(result, throwsA(anything));
    await sent.future;
    await transfer.cancel();
    await failed;
    expect(await File(path).exists(), isFalse);
    final length = await File('$path.download').exists()
        ? await File('$path.download').length()
        : 0;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      await File('$path.download').exists()
          ? await File('$path.download').length()
          : 0,
      length,
    );
  });

  test('playlist URLs are rejected before fetching', () async {
    await expectLater(
      DirectVideoTransfer().download(
        uri.replace(path: '/index.m3u8'),
        '${root.path}/video',
        maxBytes: 100,
        progress: (_, _) {},
      ),
      throwsStateError,
    );
  });
}
