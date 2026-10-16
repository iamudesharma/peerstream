import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Keeps addon headers out of application arguments. Only the selected source
/// is proxied, on loopback, behind an unguessable per-session capability.
class ExternalVideoRelay {
  HttpServer? _server;
  HttpClient? _client;
  Future<Uri> start(Uri uri, Map<String, String> headers) async {
    if (_server != null) throw StateError('A relay is already active.');
    if (!['http', 'https'].contains(uri.scheme)) {
      throw ArgumentError('Expected a video HTTP URL.');
    }
    if (RegExp(r'\.(m3u8|mpd)$', caseSensitive: false).hasMatch(uri.path)) {
      throw StateError(
        'This playlist requires addon headers. Use the built-in player or choose a video-file source.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 30);
    _server = server;
    _client = client;
    final random = Random.secure();
    final capability = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '/$capability/video';
    server.listen((request) async {
      try {
        if (request.uri.path != path ||
            request.uri.hasQuery ||
            request.headers.value('origin') != null) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        if (!['GET', 'HEAD'].contains(request.method)) {
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
          return;
        }
        final upstream = await client
            .openUrl(request.method, uri)
            .timeout(const Duration(seconds: 30));
        for (final entry in headers.entries) {
          if (![
            'host',
            'connection',
            'content-length',
            'range',
            'if-range',
            'accept-encoding',
          ].contains(entry.key.toLowerCase())) {
            upstream.headers.set(entry.key, entry.value);
          }
        }
        upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        for (final name in ['range', 'if-range']) {
          final value = request.headers.value(name);
          if (value != null) upstream.headers.set(name, value);
        }
        final response = await upstream.close().timeout(
          const Duration(seconds: 30),
        );
        request.response.statusCode = response.statusCode;
        for (final name in [
          'content-type',
          'content-range',
          'content-length',
          'accept-ranges',
          'etag',
          'last-modified',
        ]) {
          final value = response.headers.value(name);
          if (value != null) request.response.headers.set(name, value);
        }
        if (request.method != 'HEAD') {
          await request.response.addStream(
            response.timeout(const Duration(seconds: 30)),
          );
        }
        await request.response.close();
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
        } catch (_) {}
      }
    });
    return Uri.parse('http://127.0.0.1:${server.port}$path');
  }

  Future<void> close() async {
    _client?.close(force: true);
    _client = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}
