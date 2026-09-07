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

/// Native bridge revision. Must match `kBridgeVersion` in
/// `packages/libtorrent_flutter/src/torrent_bridge.cpp`. Bump both together
/// so runtime diagnostics can confirm all platforms ship the same native
/// implementation before comparing performance.
const nativeBridgeVersion = 'bridge-1.5.0+lt2.0.11';

class NativeTorrentEngine
    implements
        TorrentEngine,
        FileCompletenessChecker,
        EngineDiagnosticsProvider,
        TorrentAvailabilityProvider {
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
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
      // 250ms polls halve buffering UI latency vs 500ms; the native poll
      // only emits on change so idle cost stays low.
      pollInterval: const Duration(milliseconds: 250),
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
  String get bridgeVersion => nativeBridgeVersion;

  @override
  Future<EngineDiagnostics> engineDiagnostics() async {
    final engine = _engine;
    if (engine == null) {
      return EngineDiagnostics(bridgeVersion: bridgeVersion);
    }
    // Cache capacity is the coordinated byte budget enforced by the native
    // scheduler (see torrent_bridge.cpp StreamScheduler). Pending disk-read
    // results count against the same budget; actively served pieces are
    // never evicted.
    final capacity = Platform.isAndroid ? 64 * 1024 * 1024 : 128 * 1024 * 1024;
    int? filled;
    try {
      final firstStream = _streamIds.values.firstOrNull;
      if (firstStream != null) {
        filled = engine.getCacheState(firstStream)?.$2;
      }
    } catch (_) {}
    // Report the exact native revision when the binary provides it; fall
    // back to the Dart constant for older prebuilts.
    String reported = bridgeVersion;
    try {
      final native = engine.bridgeVersion;
      if (native.isNotEmpty) reported = native;
    } catch (_) {}
    return EngineDiagnostics(
      bridgeVersion: reported,
      cacheCapacityBytes: capacity,
      cacheFilledBytes: filled,
      activeStreams: engine.activeStreamCount,
    );
  }

  @override
  Future<bool> isFileComplete(
    TorrentHandle handle,
    TorrentFileEntry file,
  ) async {
    try {
      final id = _id(handle);
      // Native piece-level verification first: every piece of the selected
      // file must be downloaded and hash-verified. Rejects sparse files.
      try {
        if (_native.isFileComplete(id, file.index)) return true;
      } catch (_) {}
      final info = _native.torrents[id];
      // Fallback for older binaries without the symbol: require verified
      // torrent completion, not just a preallocated file length.
      if (info == null) return false;
      if (!info.isFinished) return false;
      if (info.progress < 0.999) return false;
      if (file.size <= 0) return false;
      if (info.totalWanted > 0 && info.totalDone < (info.totalWanted * 0.999)) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fast polling during startup/seeking, relaxed during steady playback.
  /// The native poll only emits on change so idle cost stays low.
  void useStartupPolling() {
    try {
      _engine?.setPollInterval(const Duration(milliseconds: 250));
    } catch (_) {}
  }

  void useSteadyPolling() {
    try {
      _engine?.setPollInterval(const Duration(seconds: 1));
    } catch (_) {}
  }

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
    int? torrentId;
    if (source.inputType == TorrentInputType.magnet) {
      torrentId = _native.addMagnet(
        source.uri.toString(),
        torrentDirectory.path,
        true,
      );
    } else {
      final file = File(
        '${torrentDirectory.path}${Platform.pathSeparator}source.torrent',
      );
      // Reuse a fresh .torrent file to skip re-download on replay/prefetch.
      // The directory is per-source (cacheKey includes the URI), so reuse is safe.
      try {
        if (await file.exists()) {
          final stat = await file.stat();
          final age = DateTime.now().difference(stat.modified);
          if (stat.size > 0 && age < const Duration(hours: 24)) {
            try {
              torrentId = _native.addTorrentFile(
                file.path,
                torrentDirectory.path,
                true,
              );
            } catch (_) {
              torrentId = null;
            }
          }
        }
      } catch (_) {
        torrentId = null;
      }
      if (torrentId == null) {
        await _dio.downloadUri(
          source.uri,
          file.path,
          options: Options(headers: source.headers),
        );
        torrentId = _native.addTorrentFile(
          file.path,
          torrentDirectory.path,
          true,
        );
      }
    }
    final id = torrentId;
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
    try {
      await _native.torrentUpdates
          .firstWhere((all) {
            final torrent = all[id];
            if (torrent != null && torrent.errorMsg.isNotEmpty) {
              throw StateError(torrent.errorMsg);
            }
            return torrent?.hasMetadata == true;
          })
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw StateError(
        'This torrent did not share its file list within 90 seconds '
        '(no metadata from peers/trackers). Try a Direct source or one '
        'with more seeds.',
      );
    }
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

  /// Verified availability snapshot for the selected file: whole-file
  /// verification plus the native stream scheduler's contiguous window
  /// ahead of its read head. Raw byte/piece signals only — callers map to
  /// media time with `torrentAvailabilityToBufferedRanges`. Returns `null`
  /// when the engine has no data for [torrentId] (not loaded, torn down).
  @override
  TorrentFileAvailability? fileAvailability(int torrentId, int fileIndex) {
    final engine = _engine;
    if (engine == null) return null;
    try {
      lt.StreamInfo? stream;
      for (final s in engine.streams.values) {
        if (s.torrentId == torrentId) {
          stream = s;
          break;
        }
      }
      return TorrentFileAvailability(
        // Sync native verified check (raw ids); never the async
        // handle-based `FileCompletenessChecker` override.
        isComplete: engine.isFileComplete(torrentId, fileIndex),
        fileSizeBytes: stream?.fileSize ?? 0,
        readHeadBytes: stream?.readHead ?? 0,
        bufferedSecondsAhead: stream?.bufferSeconds ?? 0,
        bufferedPiecesAhead: stream?.bufferPieces ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
