import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class ServiceCommandException extends StateError {
  ServiceCommandException(super.message, {required this.statusCode, this.code});
  final int statusCode;
  final String? code;
}

/// On-demand prototype owner. Bootstrap secrets never enter argv or logs.
class LocalServiceClient {
  LocalServiceClient({
    required this.executable,
    required this.library,
    required this.root,
    this.ensureStorage,
  });
  final String executable;
  final String library;
  final String root;
  final Future<void> Function()? ensureStorage;
  Process? _process;
  HttpClient? _http;
  Uri? _base;
  String? instance;
  String? _token;
  Future<void>? _starting;
  Future<void>? _closing;
  final snapshots = StreamController<Map<String, dynamic>>.broadcast();
  Future<void>? _events;
  String? failure;
  bool _dead = false;
  int? get processId => _process?.pid;

  /// True only before launch, after confirmed exit, or after completed shutdown.
  bool get hasExited => _process == null || _dead;

  Future<void> start({bool restart = false}) async {
    if (_dead) {
      if (!restart) {
        throw StateError('Streaming service stopped; retry playback.');
      }
      await close();
    }
    try {
      await (_starting ??= _start());
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> _start() async {
    if (_closing != null) throw StateError('Service is stopping');
    _dead = false;
    await ensureStorage?.call();
    await Directory(root).create(recursive: true);
    final logs = await Directory('$root/logs').create(recursive: true);
    final random = Random.secure();
    _token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      final process = await Process.start(
        executable,
        ['--root', root, '--native', library],
        environment: {'TMPDIR': '${logs.path}/'},
        includeParentEnvironment: true,
      );
      _process = process;
      // Drain diagnostics without exposing addon URLs or tokens in Flutter logs.
      process.stderr.drain<void>();
      process.stdin.writeln(jsonEncode({'token': _token}));
      await process.stdin.flush();
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final ready = jsonDecode(line) as Map;
      if (ready['protocol'] != 1) {
        throw StateError('Unsupported service protocol');
      }
      instance = ready['instance'] as String;
      _base = Uri.parse('http://127.0.0.1:${ready['port']}');
      _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      _events = _receiveEvents();
      unawaited(
        process.exitCode.then((_) {
          if (identical(_process, process) && _closing == null) {
            _dead = true;
            failure =
                'Streaming service stopped. Retry to create a new session.';
            snapshots.addError(StateError(failure!));
          }
        }),
      );
    } catch (_) {
      await _process?.stdin.close();
      _process?.kill();
      _http?.close(force: true);
      rethrow;
    }
  }

  Future<HttpClientRequest> _request(String method, String path) async {
    final request = await _http!.openUrl(method, _base!.resolve(path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    return request;
  }

  Future<Map<String, dynamic>> health() async {
    await start();
    final request = await _request('GET', '/v1/health');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw StateError('Service unavailable');
    return Map<String, dynamic>.from(
      jsonDecode(await response.transform(utf8.decoder).join()) as Map,
    );
  }

  Future<dynamic> command(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    await start();
    if (_closing != null) throw StateError('Service is stopping');
    final request = await _request('POST', '/v1/command');
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'op': op,
        'args': {...args, 'instance': instance},
      }),
    );
    final response = await request.close().timeout(
      const Duration(seconds: 95),
      onTimeout: () {
        request.abort();
        throw TimeoutException('Service command timed out');
      },
    );
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    if (response.statusCode != 200) {
      throw ServiceCommandException(
        (body as Map)['error'] as String? ?? 'Service command failed',
        statusCode: response.statusCode,
        code: body['code'] as String?,
      );
    }
    if (op != 'shutdown' && body['instance'] != instance) {
      throw StateError('Service restarted; prepare this source again');
    }
    return body['data'];
  }

  Future<void> _receiveEvents() async {
    while (_closing == null && !_dead) {
      try {
        final request = await _request('GET', '/v1/events');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw StateError('Service events unavailable');
        }
        await for (final line
            in response
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (!line.startsWith('data:')) continue;
          final data = Map<String, dynamic>.from(
            jsonDecode(line.substring(5).trim()) as Map,
          );
          if (data['instance'] != instance) {
            throw StateError('Service instance changed');
          }
          failure = null;
          if (!snapshots.isClosed) snapshots.add(data);
        }
      } catch (_) {
        if (_closing == null) failure = 'Service connection interrupted';
      }
      if (_closing == null) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> close() {
    final current = _closing;
    if (current != null) return current;
    final work = _close().then<void>((_) {
      _process = null;
      _http = null;
      _base = null;
      instance = null;
      _events = null;
      failure = null;
      _dead = false;
    });
    _closing = work;
    // Retain process ownership on a shutdown failure; do not start a second
    // writer while the old child's exit is still unconfirmed.
    work.then<void>(
      (_) {
        _starting = null;
        _closing = null;
      },
      onError: (Object _, StackTrace _) {
        _starting = null;
        _closing = null;
      },
    );
    return work;
  }

  Future<void> _close() async {
    // The private pipe is the lifetime lease. Closing it also handles UI crashes.
    try {
      await _process?.stdin.close();
    } catch (_) {}
    _http?.close(force: true);
    try {
      await _process?.exitCode.timeout(const Duration(seconds: 8));
    } catch (_) {
      _process?.kill(ProcessSignal.sigkill);
      await _process?.exitCode.timeout(const Duration(seconds: 5));
    }
    await _events;
  }
}
