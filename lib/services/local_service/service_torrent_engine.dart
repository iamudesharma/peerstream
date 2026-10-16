import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/torrent_models.dart';
import '../playback/torrent_cache_identity.dart';
import '../torrent/source_policy_loader.dart';
import '../torrent/torrent_engine.dart';
import 'service_client.dart';

/// Explicit experimental adapter. No automatic fallback while a service owns data.
class ServiceTorrentEngine
    implements
        MemoryPressureController,
        OfflineDownloadController,
        HttpServerDiagnosticsProvider,
        TorrentEngine,
        FileCompletenessChecker,
        EngineDiagnosticsProvider,
        TorrentAvailabilityProvider,
        StreamPositionController,
        StreamTimingProvider,
        WebSeedSupport,
        TorrentStatePersistence,
        ResourceProfileController {
  ServiceTorrentEngine(this.client);
  final LocalServiceClient client;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _latest = <String, Map<String, dynamic>>{};
  final _stats = StreamController<Map<String, dynamic>>.broadcast();
  final _sources = <String, String>{};
  final _remote = <String, String>{};
  final _addFlights = <String, Future<TorrentHandle>>{};
  int _nextId = 0;
  String? _instance;
  String _bridge = 'service:not-started';
  bool _cachedMetadataResume = false;
  PlaybackResourceProfile _profile = PlaybackResourceProfile.balanced;
  @override
  Future<void> handleMemoryPressure() async {
    await client.command('profile', {'lowMemory': true});
  }

  @override
  bool get isSupported => Platform.isMacOS;
  @override
  String? get unsupportedReason =>
      isSupported ? null : 'The experimental service is macOS-only.';
  @override
  String get bridgeVersion => _bridge;
  @override
  Future<void> initialize() async {
    await client.start(restart: true);
    if (_instance != null && _instance != client.instance) {
      _sources.clear();
      _remote.clear();
      _latest.clear();
    }
    _instance = client.instance;
    final health = await client.health();
    _bridge = health['bridgeVersion'] as String;
    _cachedMetadataResume =
        (health['capabilities'] as Map?)?['cachedMetadataResume'] == true;
    _subscription ??= client.snapshots.stream.listen(
      (event) {
        for (final row in (event['sessions'] as List? ?? []).whereType<Map>()) {
          final data = Map<String, dynamic>.from(row);
          final local = _remote.entries
              .where((e) => e.value == data['session'])
              .firstOrNull
              ?.key;
          if (local == null) continue;
          data['session'] = local;
          _latest[local] = data;
          if (!_stats.isClosed) _stats.add(data);
        }
      },
      onError: (Object error) {
        if (!_stats.isClosed) _stats.addError(error);
      },
    );
    await client.command('profile', {
      'lowMemory': _profile == PlaybackResourceProfile.lowMemory,
    });
  }

  @override
  void setResourceProfile(PlaybackResourceProfile profile) {
    _profile = profile;
    if (client.instance != null) {
      unawaited(
        client
            .command('profile', {
              'lowMemory': profile == PlaybackResourceProfile.lowMemory,
            })
            .catchError((Object _) => null),
      );
    }
  }

  Future<dynamic> _call(String op, [Map<String, dynamic> args = const {}]) =>
      client.command(op, {
        ...args,
        if (args['session'] != null)
          'session': _remote[args['session']] ?? args['session'],
      });
  @override
  Future<HttpServerInfo> httpServerInfo() async {
    final row = _latest.values.where((e) => e['stream'] != null).firstOrNull;
    return HttpServerInfo(
      status: row == null
          ? HttpServerStatus.notStarted
          : HttpServerStatus.running,
      url: row == null
          ? null
          : Uri.parse((row['stream'] as Map)['url'] as String),
    );
  }

  @override
  Future<void> downloadFile(TorrentHandle handle, TorrentFileEntry file) async {
    await _call('download', {'session': handle.id, 'fileIndex': file.index});
  }

  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    final key = torrentCacheKey(source);
    final existing = _addFlights[key];
    if (existing != null) return existing;
    final work = _add(source);
    _addFlights[key] = work;
    try {
      return await work;
    } finally {
      if (identical(_addFlights[key], work)) _addFlights.remove(key);
    }
  }

  Future<TorrentHandle> _add(TorrentSource source) async {
    await initialize();
    final violation = (await loadSourcePolicy()).check(source);
    if (violation != null) throw violation;
    final key = torrentCacheKey(source);
    final existing = _sources[key];
    if (existing != null) {
      try {
        await _call('snapshot', {'session': existing});
        return TorrentHandle(existing);
      } catch (_) {
        _sources.remove(key);
        _remote.remove(existing);
        _latest.remove(existing);
      }
    }
    final args = <String, dynamic>{
      'cacheKey': key,
      'requestId':
          '$key-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
    };
    Map? cached;
    if (source.inputType == TorrentInputType.torrentUrl &&
        _cachedMetadataResume) {
      try {
        cached =
            await client.command('add', {...args, 'resumeOnly': true}) as Map;
      } on ServiceCommandException catch (error) {
        if (error.statusCode != 422 || error.code != 'cache_miss') rethrow;
      }
    }
    if (source.inputType == TorrentInputType.magnet) {
      args['magnet'] = source.uri.toString();
    } else if (source.inputType == TorrentInputType.torrentUrl &&
        cached == null) {
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await http.getUrl(source.uri);
        source.headers.forEach(req.headers.set);
        final response = await req.close().timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw StateError('Torrent metadata could not be downloaded');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            throw StateError('Torrent metadata too large');
          }
        }
        args['torrent'] = bytes;
      } finally {
        http.close(force: true);
      }
    } else if (cached == null) {
      throw UnsupportedError('Direct URLs bypass the torrent service');
    }
    final data = cached ?? await client.command('add', args) as Map;
    final id = '${++_nextId}';
    _remote[id] = data['session'] as String;
    _sources[key] = id;
    return TorrentHandle(id);
  }

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    do {
      final status = await _call('snapshot', {'session': handle.id}) as Map;
      if (status['error'] == true) {
        throw StateError(status['message'] as String);
      }
      final files = await _call('files', {'session': handle.id}) as List;
      if (files.isNotEmpty) {
        return files.map((raw) {
          final f = raw as Map;
          return TorrentFileEntry(
            index: f['index'] as int,
            name: f['name'] as String,
            size: f['size'] as int,
            isStreamable: f['isStreamable'] as bool,
          );
        }).toList();
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } while (DateTime.now().isBefore(deadline));
    throw TimeoutException('This source did not provide video information');
  }

  TorrentStats _decode(Map<String, dynamic> s) {
    if (s['error'] == true) {
      throw StateError(
        s['message'] as String? ?? 'The source stopped delivering video. Retry or choose another source.',
      );
    }
    final stream = s['stream'] as Map? ?? {};
    return TorrentStats(
      name: s['name'] as String?,
      phase: s['phase'] as String? ?? 'idle',
      progress: (s['progress'] as num? ?? 0).toDouble(),
      downloadRate: s['downloadRate'] as int? ?? 0,
      uploadRate: s['uploadRate'] as int? ?? 0,
      downloadedBytes: s['downloadedBytes'] as int? ?? 0,
      totalBytes: s['totalBytes'] as int? ?? 0,
      peers: s['peers'] as int?,
      seeds: s['seeds'] as int?,
      activePieceDeadlines: stream['activeDeadlines'] as int? ?? 0,
      targetBufferSeconds: (stream['targetBufferSeconds'] as num? ?? 0)
          .toDouble(),
      cachedVerifiedBytes: stream['cachedVerifiedBytes'] as int? ?? 0,
      newlyDownloadedBytes: stream['newlyDownloadedBytes'] as int? ?? 0,
      localRereadBytes: stream['localRereadBytes'] as int? ?? 0,
    );
  }

  @override
  Stream<TorrentStats> watch(TorrentHandle handle) async* {
    if (_latest[handle.id] case final snapshot?) yield _decode(snapshot);
    yield* _stats.stream.where((s) => s['session'] == handle.id).map(_decode);
  }

  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async {
    final snapshot = Map<String, dynamic>.from(
      await _call('start', {'session': handle.id, 'fileIndex': file.index})
          as Map,
    );
    snapshot['session'] = handle.id;
    _latest[handle.id] = snapshot;
    final uri = Uri.parse((snapshot['stream'] as Map)['url'] as String);
    if (uri.host != '127.0.0.1' || uri.scheme != 'http') {
      throw StateError('Invalid service stream endpoint');
    }
    return TorrentPlaybackStream(id: handle.id, uri: uri, file: file);
  }

  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    if (_remote.containsKey(handle.id) && !client.hasExited) {
      await _call('release', {'session': handle.id});
    }
    final keys = _sources.entries
        .where((e) => e.value == handle.id)
        .map((e) => e.key)
        .toList();
    for (final key in keys) {
      _sources.remove(key);
      if (deleteFiles) await client.command('cacheRemove', {'cacheKey': key});
    }
    _latest.remove(handle.id);
    _remote.remove(handle.id);
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await client.close();
    _subscription = null;
    _instance = null;
    _sources.clear();
    _addFlights.clear();
    _remote.clear();
    _latest.clear();
  }

  @override
  Future<bool> isFileComplete(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async =>
      await _call('complete', {
        'session': handle.id,
        'fileIndex': file.index,
      }) ==
      true;
  @override
  void setStreamPosition(
    TorrentHandle handle,
    int byteOffset, {
    int windowBytes = 0,
    bool urgent = false,
  }) {
    unawaited(
      _call('position', {
        'session': handle.id,
        'byteOffset': byteOffset,
        'windowBytes': windowBytes,
        'urgent': urgent,
      }).catchError((Object _) => null),
    );
  }

  @override
  void setStreamDuration(TorrentHandle handle, int durationMs) {
    unawaited(
      _call('duration', {
        'session': handle.id,
        'durationMs': durationMs,
      }).catchError((Object _) => null),
    );
  }

  @override
  int? streamReadHead(TorrentHandle handle) =>
      (_latest[handle.id]?['stream'] as Map?)?['readHeadBytes'] as int?;
  @override
  String? streamDebugSnapshot(TorrentHandle handle) =>
      _latest[handle.id] == null
      ? null
      : jsonEncode({'service': client.instance, 'session': handle.id});
  @override
  TorrentFileAvailability? fileAvailability(int torrentId, int fileIndex) =>
      sessionAvailability(TorrentHandle('$torrentId'));
  // Native ids are opaque in this adapter. Consumers can use sessionAvailability.
  TorrentFileAvailability? sessionAvailability(TorrentHandle handle) {
    final s = _latest[handle.id]?['stream'] as Map?;
    if (s == null) return null;
    return TorrentFileAvailability(
      isComplete: s['isComplete'] == true,
      fileSizeBytes: s['fileSizeBytes'] as int,
      readHeadBytes: s['readHeadBytes'] as int,
      bufferedSecondsAhead: (s['bufferedSecondsAhead'] as num).toDouble(),
      bufferedPiecesAhead: s['bufferedPiecesAhead'] as int,
    );
  }

  @override
  TorrentStreamTimings? streamTimings(TorrentHandle handle) {
    final s = _latest[handle.id]?['stream'] as Map?;
    if (s == null) return null;
    DateTime? at(String key) {
      final ms = s[key] as int? ?? 0;
      return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    }

    return TorrentStreamTimings(
      firstRangeRequestAt: at('firstRangeMs'),
      firstPieceRequestedAt: at('firstPieceRequestedMs'),
      firstPieceCompletedAt: at('firstPieceCompletedMs'),
      firstByteSentAt: at('firstByteMs'),
      lastSeekResponseMs: s['lastSeekResponseMs'] as int?,
      activeDeadlines: s['activeDeadlines'] as int? ?? 0,
      targetBufferSeconds: (s['targetBufferSeconds'] as num? ?? 0).toDouble(),
      cachedVerifiedBytes: s['cachedVerifiedBytes'] as int? ?? 0,
      newlyDownloadedBytes: s['newlyDownloadedBytes'] as int? ?? 0,
      localRereadBytes: s['localRereadBytes'] as int? ?? 0,
    );
  }

  @override
  Future<EngineDiagnostics> engineDiagnostics() async {
    final h = await client.health();
    return EngineDiagnostics(
      bridgeVersion: h['bridgeVersion'] as String,
      processMemoryBytes: h['physicalFootprintBytes'] as int?,
      cacheCapacityBytes: h['pieceCacheBudgetBytes'] as int,
      activeStreams: (_latest.values.where((v) => v['stream'] != null)).length,
    );
  }

  @override
  void addWebSeed(TorrentHandle handle, String url) {
    unawaited(
      _call('webSeed', {
        'session': handle.id,
        'url': url,
      }).catchError((Object _) => null),
    );
  }

  @override
  Future<void> persistSessionState() async {
    await client.command('persist');
  }
}
