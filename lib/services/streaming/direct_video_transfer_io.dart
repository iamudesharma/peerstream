import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Streams a finite HTTP video to the selected cache, never through a RAM buffer.
/// A partial file is resumed only with a server validator and exact Content-Range.
class DirectVideoTransfer {
  HttpClient? _client;
  Future<int>? _running;
  bool _cancelled = false;
  Future<int> download(
    Uri uri,
    String path, {
    required int maxBytes,
    Map<String, String> headers = const {},
    required void Function(int, int) progress,
  }) {
    if (_running != null) {
      throw StateError('A direct download is already active.');
    }
    _cancelled = false;
    final work = _download(uri, path, maxBytes, headers, progress);
    _running = work;
    return work.whenComplete(() {
      _running = null;
    });
  }

  Future<int> _download(
    Uri uri,
    String path,
    int maxBytes,
    Map<String, String> headers,
    void Function(int, int) progress,
  ) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw StateError('Choose an HTTP video file to download.');
    }
    if (RegExp(r'\.(m3u8|mpd)$', caseSensitive: false).hasMatch(uri.path)) {
      throw StateError(
        'This is a streaming playlist. Choose a video-file or torrent source to download.',
      );
    }
    final partial = File('$path.download');
    final metadata = File('$path.download.json');
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 30);
    _client = client;
    RandomAccessFile? output;
    try {
      var offset = await partial.exists() ? await partial.length() : 0;
      String? validator;
      if (await metadata.exists()) {
        try {
          final saved =
              jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          if (saved['uri'] == uri.toString()) {
            validator = saved['validator'] as String?;
          }
        } catch (_) {
          validator = null;
        }
      }
      if (validator == null) offset = 0;
      final request = await client
          .getUrl(uri)
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
          request.headers.set(entry.key, entry.value);
        }
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (offset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        request.headers.set(HttpHeaders.ifRangeHeader, validator!);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding != 'identity') {
        throw StateError(
          'The server returned a compressed transfer that cannot be safely resumed. Choose another source.',
        );
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.contains('mpegurl') ||
          type.contains('dash+xml') ||
          type.contains('text/html') ||
          type.contains('application/json')) {
        throw StateError(
          'This source is not a downloadable video file. Choose another source.',
        );
      }
      var total = response.contentLength;
      if (response.statusCode == HttpStatus.partialContent && offset > 0) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) != int.parse(range[3]!) - 1) {
          if (await metadata.exists()) await metadata.delete();
          throw StateError(
            'The server returned an invalid resume range. Retry to restart the download.',
          );
        }
        final returnedValidator = validator!.startsWith('"')
            ? response.headers.value(HttpHeaders.etagHeader)
            : response.headers.value(HttpHeaders.lastModifiedHeader);
        if (returnedValidator != null && returnedValidator != validator) {
          if (await metadata.exists()) await metadata.delete();
          throw StateError(
            'The source changed. Retry the download from the beginning.',
          );
        }
        total = int.parse(range[3]!);
        if (response.contentLength >= 0 &&
            response.contentLength != total - offset) {
          throw StateError('The server returned an inconsistent video size.');
        }
      } else if (response.statusCode == HttpStatus.ok) {
        offset = 0; // If-Range mismatch or no Range support: restart safely.
      } else {
        throw StateError(
          'The server could not provide the video (${response.statusCode}).',
        );
      }
      if (total > maxBytes || offset > maxBytes) {
        throw StateError('This download exceeds the storage budget.');
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final nextValidator = etag != null && !etag.startsWith('W/')
          ? etag
          : response.headers.value(HttpHeaders.lastModifiedHeader);
      await metadata.writeAsString(
        jsonEncode({'uri': uri.toString(), 'validator': nextValidator}),
        flush: true,
      );
      output = await partial.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var bytes = offset;
      progress(bytes, total > 0 ? total : 0);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw StateError('Download paused.');
        bytes += chunk.length;
        if (bytes > maxBytes || (total >= 0 && bytes > total)) {
          throw StateError(
            'The video exceeds its declared size or storage budget.',
          );
        }
        await output.writeFrom(chunk);
        progress(bytes, total > 0 ? total : 0);
      }
      if (_cancelled) throw StateError('Download paused.');
      if (bytes == 0 || (total >= 0 && bytes != total)) {
        throw StateError('The download ended before the video was complete.');
      }
      await output.flush();
      await output.close();
      output = null;
      if (_cancelled) throw StateError('Download paused.');
      await partial.rename(path);
      if (await metadata.exists()) await metadata.delete();
      return bytes;
    } finally {
      await output?.close();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _client?.close(force: true);
    try {
      await _running;
    } catch (_) {}
  }
}
