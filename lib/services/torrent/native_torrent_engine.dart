import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;
import 'package:path_provider/path_provider.dart';

import '../../models/torrent_models.dart';
import '../playback/playback_cache.dart';
import '../playback/torrent_cache_identity.dart';
import 'torrent_engine.dart';
import 'source_policy_loader.dart';

class NativeTorrentEngine implements TorrentEngine {
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );
  final Map<int, int> _streamIds = {};
  final Map<String, int> _retainedTorrents = {};
  final PlaybackCacheStore _cache = PlaybackCacheStore();
  Directory? _sessionDirectory;
  lt.LibtorrentFlutter? _engine;

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  Future<void> initialize() async {
    if (_engine != null) return;
    final cache = await getApplicationCacheDirectory();
    _sessionDirectory = await Directory(
      '${cache.path}${Platform.pathSeparator}peerstream-session',
    ).create(recursive: true);
    await lt.LibtorrentFlutter.init(
      defaultSavePath: _sessionDirectory!.path,
      pollInterval: const Duration(milliseconds: 500),
      // Addon magnets already carry their own tracker set. The package's
      // optional remote list injects hundreds more and emits each tracker
      // alert through Dart, which can starve the player during startup.
      fetchTrackers: false,
    );
    _engine = lt.LibtorrentFlutter.instance;
    _engine!.configureSession(
      const lt.BtConfig(
        cacheSize: 128 * 1024 * 1024,
        readerReadAhead: 85,
        preloadCache: 10,
        connectionsLimit: 32,
        torrentDisconnectTimeout: 120,
        responsiveMode: true,
      ),
    );
  }

  lt.LibtorrentFlutter get _native =>
      _engine ?? (throw StateError('Torrent engine is not initialized.'));

  @override
  Future<TorrentHandle> add(TorrentSource source) async {
    await initialize();
    final violation = (await loadSourcePolicy()).check(source);
    if (violation != null) throw violation;
    final cacheKey = torrentCacheKey(source);
    final retainedId = _retainedTorrents[cacheKey];
    if (retainedId != null && _native.torrents.containsKey(retainedId)) {
      _native.resumeTorrent(retainedId);
      return TorrentHandle('$retainedId');
    }
    final torrentDirectory = Directory(await _cache.directoryPathFor(source));
    late final int id;
    if (source.inputType == TorrentInputType.magnet) {
      id = _native.addMagnet(
        source.uri.toString(),
        torrentDirectory.path,
        true,
      );
    } else {
      final file = File(
        '${torrentDirectory.path}${Platform.pathSeparator}source.torrent',
      );
      await _dio.downloadUri(
        source.uri,
        file.path,
        options: Options(headers: source.headers),
      );
      id = _native.addTorrentFile(file.path, torrentDirectory.path, true);
    }
    _retainedTorrents[cacheKey] = id;
    return TorrentHandle('$id');
  }

  int _id(TorrentHandle handle) => int.parse(handle.id);

  @override
  Future<List<TorrentFileEntry>> waitForFiles(TorrentHandle handle) async {
    final id = _id(handle);
    List<TorrentFileEntry> readFiles() => _native.getFiles(id).map((file) {
      return TorrentFileEntry(
        index: file.index,
        name: file.name,
        size: file.size,
        isStreamable: file.isStreamable,
      );
    }).toList();
    final current = _native.torrents[id];
    if (current?.hasMetadata == true) return readFiles();
    await _native.torrentUpdates
        .firstWhere((all) {
          final torrent = all[id];
          if (torrent != null && torrent.errorMsg.isNotEmpty) {
            throw StateError(torrent.errorMsg);
          }
          return torrent?.hasMetadata == true;
        })
        .timeout(const Duration(minutes: 5));
    return readFiles();
  }

  @override
  Stream<TorrentStats> watch(TorrentHandle handle) {
    final id = _id(handle);
    return _native.torrentUpdates.map((all) {
      final torrent = all[id];
      if (torrent == null) return const TorrentStats();
      if (torrent.errorMsg.isNotEmpty) throw StateError(torrent.errorMsg);
      final streamId = _streamIds[id];
      final stream = streamId == null ? null : _native.streams[streamId];
      return TorrentStats(
        name: torrent.name,
        phase: stream?.streamState.name ?? torrent.state.name,
        progress: torrent.progress,
        bufferProgress: stream?.bufferPct ?? 0,
        downloadRate: torrent.downloadRate,
        uploadRate: torrent.uploadRate,
        peers: torrent.numPeers,
        seeds: torrent.numSeeds,
        downloadedBytes: torrent.totalDone,
        totalBytes: torrent.totalWanted,
      );
    });
  }

  @override
  Future<TorrentPlaybackStream> startStream(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async {
    final torrentId = _id(handle);
    final stream = _native.startStream(
      torrentId,
      fileIndex: file.index,
      maxCacheBytes: Platform.isAndroid ? 64 * 1024 * 1024 : 128 * 1024 * 1024,
    );
    // Keep recently played pieces in memory and request a modest window ahead
    // of the player. This makes short rewinds and normal seeking responsive
    // without competing with the urgent startup pieces.
    _native.setCacheSettings(
      stream.id,
      capacity: Platform.isAndroid ? 64 * 1024 * 1024 : 128 * 1024 * 1024,
      readAheadPct: 85,
      connectionsLimit: 32,
    );
    _native.preloadStream(
      stream.id,
      preloadBytes: Platform.isAndroid ? 4 * 1024 * 1024 : 8 * 1024 * 1024,
    );
    _streamIds[torrentId] = stream.id;
    return TorrentPlaybackStream(
      id: '${stream.id}',
      uri: Uri.parse(stream.url),
      file: file,
    );
  }

  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    final id = _id(handle);
    _native.stopAllStreamsForTorrent(id);
    if (deleteFiles) {
      _native.removeTorrent(id, deleteFiles: true);
      _retainedTorrents.removeWhere((_, torrentId) => torrentId == id);
    } else {
      // Keeping the handle avoids a second metadata exchange and preserves the
      // verified piece map for replay during this app session.
      _native.pauseTorrent(id);
    }
    _streamIds.remove(id);
  }

  @override
  Future<void> dispose() async {
    if (_engine == null) return;
    await _native.dispose();
    _engine = null;
    _retainedTorrents.clear();
  }
}
