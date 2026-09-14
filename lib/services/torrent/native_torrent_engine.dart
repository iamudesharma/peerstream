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
const nativeBridgeVersion = 'bridge-1.7.0+lt2.0.11';

class NativeTorrentEngine
    implements
        TorrentEngine,
        TorrentStatePersistence,
        FileCompletenessChecker,
        EngineDiagnosticsProvider,
        HttpServerDiagnosticsProvider,
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
  String? _sessionStatePath;

  /// Torrent id → fast-resume file path. Populated on add; the alert thread
  /// writes the file when libtorrent reports the resume data is ready.
  final Map<int, String> _resumePaths = {};

  static const _resumeFileName = 'metadata.resume';

  lt.LibtorrentFlutter? _engine;

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  Future<HttpServerInfo> httpServerInfo() async {
    final stream = _engine?.streams.values.firstOrNull;
    if (stream == null) {
      return const HttpServerInfo(
        status: HttpServerStatus.notStarted,
        message:
            'Starts automatically when you play a torrent. '
            'Direct links and saved files do not need this server.',
      );
    }
    final url = Uri.tryParse(stream.url);
    if (url == null || !url.hasPort || url.port == 0) {
      return const HttpServerInfo(
        status: HttpServerStatus.unavailable,
        message: 'The streaming server has not provided a valid address.',
      );
    }
    try {
      final response = await _dio.headUri<void>(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      // A stopped/replaced stream must not be reported as still running.
      if (_engine?.streams[stream.id]?.url != stream.url) {
        return const HttpServerInfo(status: HttpServerStatus.notStarted);
      }
      final healthy = response.statusCode == 200 || response.statusCode == 206;
      return HttpServerInfo(
        status: healthy
            ? HttpServerStatus.running
            : HttpServerStatus.unavailable,
        url: url,
        message: healthy
            ? null
            : 'Server returned HTTP ${response.statusCode}.',
      );
    } catch (_) {
      return HttpServerInfo(
        status: HttpServerStatus.unavailable,
        url: url,
        message:
            'The local streaming server is not responding. Try refreshing.',
      );
    }
  }

  @override
  Future<void> initialize() async {
    if (_engine != null) return;
    final cache = await getApplicationCacheDirectory();
    _sessionDirectory = await Directory(
      '${cache.path}${Platform.pathSeparator}peerstream-session',
    ).create(recursive: true);
    // DHT routing state lives in application support (not the prunable
    // cache) so repeat launches can skip re-bootstrapping the DHT.
    try {
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      _sessionStatePath =
          '${support.path}${Platform.pathSeparator}libtorrent-session.state';
    } catch (_) {
      _sessionStatePath = null;
    }
    await lt.LibtorrentFlutter.init(
      defaultSavePath: _sessionDirectory!.path,
      sessionStatePath: _sessionStatePath,
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
        // Startup is demand-driven: the player opens the Range URL and
        // libtorrent schedules only the pieces requested by FFmpeg.
        preloadCache: 0,
        connectionsLimit: 32,
        torrentDisconnectTimeout: 120,
        responsiveMode: true,
      ),
    );
  }

  lt.LibtorrentFlutter get _native =>
      _engine ?? (throw StateError('Torrent engine is not initialized.'));

  /// Snapshot of the native stream diagnostics for one playback handle.
  /// Kept on the PeerStream adapter so torrent types never leak into
  /// MediaForge.
  lt.StreamInfo? streamInfo(TorrentHandle handle) {
    final id = _streamIds[_id(handle)];
    return id == null ? null : _engine?.streams[id];
  }

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
    final resumePath =
        '${torrentDirectory.path}${Platform.pathSeparator}$_resumeFileName';
    int? torrentId;

    // Fast-resume path: the cached resume file embeds the info-dict (so no
    // magnet metadata exchange), the verified piece map (so no disk recheck),
    // and last-known peers (so peer discovery starts warm). Both magnets and
    // .torrent URLs use it; it is written on stop and after first metadata.
    if (await File(resumePath).exists()) {
      try {
        torrentId = _native.addTorrentResume(
          resumePath,
          torrentDirectory.path,
          true,
        );
      } catch (error) {
        // Corrupt/incompatible resume: fall back to a fresh add and drop the
        // bad file so later attempts do not retry it. It is rewritten after
        // metadata/stop. An older native binary that lacks the symbol keeps
        // the file untouched.
        torrentId = null;
        if (error is! UnsupportedError) {
          try {
            await File(resumePath).delete();
          } catch (_) {}
        }
      }
    }

    if (torrentId == null) {
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
    }
    final id = torrentId;
    _retainedTorrents[cacheKey] = id;
    _resumePaths[id] = resumePath;
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
    if (current?.hasMetadata == true) {
      _scheduleResumeSave(id);
      return readFiles();
    }
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
    // Metadata is here: persist fast-resume immediately so even an abrupt
    // session end leaves a replayable info-dict behind.
    _scheduleResumeSave(id);
    return readFiles();
  }

  /// Fire-and-forget fast-resume save for [torrentId].
  void _scheduleResumeSave(int torrentId) {
    final path = _resumePaths[torrentId];
    if (path == null) return;
    try {
      _native.saveResumeData(torrentId, path);
    } catch (_) {}
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
        activePieceDeadlines: stream?.activeDeadlines ?? 0,
        targetBufferSeconds: stream?.targetBufferSeconds ?? 0,
        cachedVerifiedBytes: stream?.cachedVerifiedBytes ?? 0,
        newlyDownloadedBytes: stream?.newlyDownloadedBytes ?? 0,
        localRereadBytes: stream?.localRereadBytes ?? 0,
        firstHttpRangeAtMs: stream?.firstHttpRangeAtMs ?? 0,
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
    // Warm the container metadata window (head + tail) in the background.
    // Non-faststart MP4 files keep their moov atom at the end; without this
    // the player has to wait for tail pieces on the first-frame critical
    // path. Bounded to 16MB and interrupted by any seek.
    try {
      _native.preloadStream(stream.id);
    } catch (_) {}
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
      _resumePaths.remove(id);
    } else {
      // Persist fast-resume (verified pieces + peers) before pausing so the
      // next app launch skips metadata exchange and disk rechecks. The
      // native alert thread does the file write asynchronously.
      _scheduleResumeSave(id);
      // Keeping the handle avoids a second metadata exchange and preserves the
      // verified piece map for replay during this app session.
      _native.pauseTorrent(id);
    }
    _streamIds.remove(id);
  }

  /// Persist DHT state and fast-resume data for every known torrent. Safe to
  /// call at any time (app pause/exit, periodic tick); never throws.
  @override
  Future<void> persistSessionState() async {
    if (_engine == null) return;
    for (final entry in Map<int, String>.from(_resumePaths).entries) {
      try {
        _native.saveResumeData(entry.key, entry.value);
      } catch (_) {}
    }
    final statePath = _sessionStatePath;
    if (statePath != null) {
      try {
        _native.saveSessionState(statePath);
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async {
    if (_engine == null) return;
    await persistSessionState();
    await _native.dispose();
    _engine = null;
    _retainedTorrents.clear();
    _resumePaths.clear();
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
