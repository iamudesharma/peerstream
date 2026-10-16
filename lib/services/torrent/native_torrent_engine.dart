import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart' as lt;

import '../storage/app_storage.dart';

import '../../models/torrent_models.dart';
import '../playback/playback_cache.dart';
import '../playback/torrent_cache_identity.dart';
import 'torrent_engine.dart';
import 'source_policy_loader.dart';

/// Native bridge revision. Must match `kBridgeVersion` in
/// `packages/libtorrent_flutter/src/torrent_bridge.cpp`. Bump both together
/// so runtime diagnostics can confirm all platforms ship the same native
/// implementation before comparing performance.
const nativeBridgeVersion = 'bridge-1.9.10+lt2.1.1';

class NativeTorrentEngine
    implements
        EnginePollingController,
        HttpServerDiagnosticsProvider,
        ResourceProfileController,
        MemoryPressureController,
        InactiveHandleReleaser,
        OfflineDownloadController,
        TorrentEngine,
        FileCompletenessChecker,
        EngineDiagnosticsProvider,
        TorrentAvailabilityProvider,
        StreamPositionController,
        StreamTimingProvider,
        WebSeedSupport,
        TorrentStatePersistence {
  NativeTorrentEngine({
    PlaybackCacheStore? cache,
    Future<String> Function()? sessionCacheDirectory,
  }) : _sessionCacheDirectory =
           sessionCacheDirectory ?? appStorage.cacheDirectoryPath,
       _cache = cache ?? PlaybackCacheStore();

  @override
  Future<void> downloadFile(TorrentHandle handle, TorrentFileEntry file) async {
    final id = _id(handle);
    final files = await waitForFiles(handle);
    final highest = files
        .map((f) => f.index)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final priorities = List<int>.filled(highest + 1, 0);
    priorities[file.index] = 1;
    _idleRelease.remove(id)?.cancel();
    _native.setFilePriorities(id, priorities);
    _native.resumeTorrent(id);
    _startStateSaveTimer();
  }

  @override
  Future<void> handleMemoryPressure() async {
    for (final id in _idleRelease.keys.toList()) {
      await releaseInactive(TorrentHandle('$id'));
    }
    setResourceProfile(PlaybackResourceProfile.lowMemory);
  }

  final _metadataWaiters = <int, Set<Completer<void>>>{};
  final _idleRelease = <int, Timer>{};

  @override
  Future<void> releaseInactive(TorrentHandle handle) async {
    final id = _id(handle);
    _idleRelease.remove(id)?.cancel();
    if (_engine == null || _streamIds.containsKey(id)) return;
    _saveTorrentState(id);
    _native.removeTorrent(id, deleteFiles: false);
    _retainedTorrents.removeWhere((_, value) => value == id);
    _stateDirectories.remove(id);
  }

  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  final Map<int, int> _streamIds = {};
  final Map<String, int> _retainedTorrents = {};
  // `StreamingService` can receive a second Play while the first async add is
  // still resolving metadata/state. Keep the native session to one add per
  // cache key so two libtorrent handles never write the same payload path.
  final Map<String, Future<TorrentHandle>> _addFlights = {};
  final Map<int, String> _stateDirectories = {};
  final Map<int, Uri> _streamUrls = {};
  @override
  Future<HttpServerInfo> httpServerInfo() async => HttpServerInfo(
    status: _streamUrls.isEmpty
        ? HttpServerStatus.notStarted
        : HttpServerStatus.running,
    url: _streamUrls.values.firstOrNull,
  );
  final PlaybackCacheStore _cache;
  final Future<String> Function() _sessionCacheDirectory;
  Directory? _sessionDirectory;
  Timer? _stateSaveTimer;
  lt.LibtorrentFlutter? _engine;
  Future<void>? _initializing;

  /// Sidecar file inside each torrent directory holding libtorrent resume
  /// data: the torrent metadata (info-dict) plus the verified piece bitfield.
  static const _stateFileName = 'resume.dat';

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  Future<void> initialize() {
    final active = _initializing;
    if (active != null) return active;
    final work = _initialize();
    _initializing = work;
    work.then<void>(
      (_) => _initializing = null,
      onError: (Object _, StackTrace _) => _initializing = null,
    );
    return work;
  }

  PlaybackResourceProfile _profile = PlaybackResourceProfile.balanced;

  @override
  void setResourceProfile(PlaybackResourceProfile profile) {
    _profile = profile;
    if (_engine != null) _applyResourceProfile();
  }

  void _applyResourceProfile() {
    _engine!.configureSession(
      lt.BtConfig(
        cacheSize:
            (_profile == PlaybackResourceProfile.lowMemory ? 64 : 128) *
            1024 *
            1024,
        readerReadAhead: 85,
        preloadCache: 10,
        connectionsLimit: 32,
        torrentDisconnectTimeout: 120,
        responsiveMode: true,
      ),
    );
  }

  Future<void> _initialize() async {
    if (_engine != null) return;
    final cache = Directory(await _sessionCacheDirectory());
    _sessionDirectory = await Directory(
      '${cache.path}${Platform.pathSeparator}peerstream-session',
    ).create(recursive: true);
    await lt.LibtorrentFlutter.init(
      defaultSavePath: _sessionDirectory!.path,
      sessionStatePath: '${_sessionDirectory!.path}/dht-session.dat',
      // 250ms polls halve buffering UI latency vs 500ms; the native poll
      // only emits on change so idle cost stays low.
      pollInterval: const Duration(milliseconds: 250),
      // Addon magnets already carry their own tracker set. The package's
      // optional remote list injects hundreds more and emits each tracker
      // alert through Dart, which can starve the player during startup.
      fetchTrackers: false,
    );
    _engine = lt.LibtorrentFlutter.instance;
    _applyResourceProfile();
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
    final capacity =
        Platform.isAndroid || _profile == PlaybackResourceProfile.lowMemory
        ? 64 * 1024 * 1024
        : 128 * 1024 * 1024;
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
      processMemoryBytes: engine.processMemory()?['physicalFootprintBytes'],
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

  @override
  void setStreamPosition(
    TorrentHandle handle,
    int byteOffset, {
    int windowBytes = 0,
    bool urgent = false,
  }) {
    final streamId = _streamIds[_id(handle)];
    if (streamId == null || byteOffset <= 0) return;
    try {
      final accepted = _native.setStreamPosition(
        streamId,
        byteOffset,
        windowBytes: windowBytes,
        urgent: urgent,
      );
      if (accepted) {
        debugPrint(
          '[Torrent] stream position hint id=$streamId byte=$byteOffset '
          'window=$windowBytes urgent=${urgent ? 1 : 0}',
        );
      }
    } catch (_) {}
  }

  @override
  void setStreamDuration(TorrentHandle handle, int durationMs) {
    final streamId = _streamIds[_id(handle)];
    if (streamId == null || durationMs <= 0) return;
    try {
      _native.setStreamDuration(streamId, durationMs);
    } catch (_) {}
  }

  @override
  int? streamReadHead(TorrentHandle handle) {
    final streamId = _streamIds[_id(handle)];
    if (streamId == null) return null;
    try {
      return _native.streamStatusNow(streamId)?.readHead;
    } catch (_) {
      return null;
    }
  }

  @override
  String? streamDebugSnapshot(TorrentHandle handle) {
    final streamId = _streamIds[_id(handle)];
    if (streamId == null) return null;
    try {
      return _native.streamDebugSnapshot(streamId);
    } catch (_) {
      return null;
    }
  }

  @override
  TorrentStreamTimings? streamTimings(TorrentHandle handle) {
    final streamId = _streamIds[_id(handle)];
    if (streamId == null) return null;
    try {
      final info = _native.streamStatusNow(streamId);
      if (info == null) return null;
      DateTime? fromEpochMs(int ms) =>
          ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
      return TorrentStreamTimings(
        firstRangeRequestAt: fromEpochMs(info.firstHttpRangeAtMs),
        firstPieceRequestedAt: fromEpochMs(info.firstPieceRequestedAtMs),
        firstPieceCompletedAt: fromEpochMs(info.firstPieceCompletedAtMs),
        firstByteSentAt: fromEpochMs(info.firstByteSentAtMs),
        lastSeekResponseMs: info.lastSeekResponseMs >= 0
            ? info.lastSeekResponseMs
            : null,
        activeDeadlines: info.activeDeadlines,
        targetBufferSeconds: info.targetBufferSeconds,
        cachedVerifiedBytes: info.cachedVerifiedBytes,
        newlyDownloadedBytes: info.newlyDownloadedBytes,
        localRereadBytes: info.localRereadBytes,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void addWebSeed(TorrentHandle handle, String url) {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return;
    }
    try {
      final ok = _native.addWebSeed(_id(handle), url);
      debugPrint(
        '[Torrent] web seed ${ok ? 'attached' : 'failed'} id=${handle.id}',
      );
    } catch (_) {}
  }

  /// Fast polling during startup/seeking, relaxed during steady playback.
  /// The native poll only emits on change so idle cost stays low.
  @override
  void useStartupPolling() {
    try {
      _engine?.setPollInterval(const Duration(milliseconds: 250));
    } catch (_) {}
  }

  @override
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
    final inFlight = _addFlights[cacheKey];
    if (inFlight != null) {
      debugPrint('[Torrent] joining in-flight add key=$cacheKey');
      return inFlight;
    }
    final future = _addForKey(source, cacheKey);
    _addFlights[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_addFlights[cacheKey], future)) {
        _addFlights.remove(cacheKey);
      }
    }
  }

  Future<TorrentHandle> _addForKey(
    TorrentSource source,
    String cacheKey,
  ) async {
    final retainedId = _retainedTorrents[cacheKey];
    if (retainedId != null && _native.torrents.containsKey(retainedId)) {
      _idleRelease.remove(retainedId)?.cancel();
      _native.resumeTorrent(retainedId);
      return TorrentHandle('$retainedId');
    }
    final torrentDirectory = Directory(await _cache.directoryPathFor(source));
    // Fast path: re-add from saved resume data (metadata + verified pieces).
    // Skips the peer metadata exchange and the file recheck, so cached bytes
    // are usable immediately after a restart.
    final stateFile = File(
      '${torrentDirectory.path}${Platform.pathSeparator}$_stateFileName',
    );
    if (await stateFile.exists() &&
        await _hasTorrentPayload(torrentDirectory)) {
      final stateId = _native.addTorrentWithState(
        stateFile.path,
        torrentDirectory.path,
        true,
      );
      if (stateId != null) {
        _retainedTorrents[cacheKey] = stateId;
        _stateDirectories[stateId] = torrentDirectory.path;
        debugPrint('[Torrent] resumed from state key=$cacheKey id=$stateId');
        return TorrentHandle('$stateId');
      }
      debugPrint('[Torrent] state re-add failed for $cacheKey; falling back');
    }
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
    _stateDirectories[id] = torrentDirectory.path;
    debugPrint(
      '[Torrent] add ${source.inputType.name} key=$cacheKey '
      'dir=${torrentDirectory.path} id=$id',
    );
    return TorrentHandle('$id');
  }

  /// True when the torrent directory holds downloaded payload (not just the
  /// resume/metadata sidecars), so re-adding from resume data cannot point
  /// libtorrent at pieces that are no longer on disk.
  Future<bool> _hasTorrentPayload(Directory directory) async {
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == _stateFileName ||
            name == 'source.torrent' ||
            name.endsWith('.tmp')) {
          continue;
        }
        if (await entity.length() > 0) return true;
      }
    } catch (_) {}
    return false;
  }

  /// Writes resume data for [id] when its directory is known. Best effort:
  /// failures (no metadata yet, removed torrent) are ignored.
  void _saveTorrentState(int id) {
    final directory = _stateDirectories[id];
    if (directory == null) return;
    try {
      final saved = _native.saveTorrentState(
        id,
        '$directory${Platform.pathSeparator}$_stateFileName',
      );
      if (saved) debugPrint('[Torrent] state saved id=$id');
    } catch (_) {}
  }

  /// Periodic safety net so a killed process still leaves usable state.
  void _startStateSaveTimer() {
    _stateSaveTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
      for (final id in _stateDirectories.keys.toList()) {
        _saveTorrentState(id);
      }
      if (_sessionDirectory != null) {
        _native.saveSessionState('${_sessionDirectory!.path}/dht-session.dat');
      }
    });
  }

  @override
  Future<void> persistSessionState() async {
    try {
      if (_engine == null) return;
      for (final id in _stateDirectories.keys.toList()) {
        _saveTorrentState(id);
      }
      if (_sessionDirectory != null) {
        _native.saveSessionState('${_sessionDirectory!.path}/dht-session.dat');
      }
    } catch (_) {}
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
    final startedAt = DateTime.now();
    debugPrint('[Torrent] waiting for metadata (id=$id)');
    final completed = Completer<void>();
    final waiters = _metadataWaiters.putIfAbsent(id, () => {});
    waiters.add(completed);
    final subscription = _native.torrentUpdates.listen(
      (all) {
        final torrent = all[id];
        if (completed.isCompleted) return;
        if (torrent != null && torrent.errorMsg.isNotEmpty) {
          completed.completeError(StateError(torrent.errorMsg));
        } else if (torrent?.hasMetadata == true) {
          completed.complete();
        }
      },
      onError: (Object error) {
        if (!completed.isCompleted) completed.completeError(error);
      },
    );
    try {
      await completed.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw StateError(
        'This torrent did not share its file list within 90 seconds '
        '(no metadata from peers/trackers). Try a Direct source or one '
        'with more seeds.',
      );
    } finally {
      await subscription.cancel();
      waiters.remove(completed);
      if (waiters.isEmpty) _metadataWaiters.remove(id);
    }
    debugPrint(
      '[Torrent] metadata ready (id=$id) after '
      '${DateTime.now().difference(startedAt).inSeconds}s',
    );
    // Persist metadata + pieces as soon as the info-dict is known, so even a
    // failed playback leaves a resumable state file behind.
    _saveTorrentState(id);
    return readFiles();
  }

  @override
  Stream<TorrentStats> watch(TorrentHandle handle) {
    final id = _id(handle);
    return _native.torrentUpdates.asyncMap((all) async {
      final session = _sessionDirectory;
      if (session != null && !await session.exists()) {
        _native.pauseTorrent(id);
        throw const StorageUnavailableException(
          'Storage drive disconnected. Reconnect it or choose another folder in Playback & Storage.',
        );
      }
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
      capacity:
          Platform.isAndroid || _profile == PlaybackResourceProfile.lowMemory
          ? 64 * 1024 * 1024
          : 128 * 1024 * 1024,
      readAheadPct: 85,
      connectionsLimit: 32,
    );
    _native.preloadStream(
      stream.id,
      preloadBytes: Platform.isAndroid ? 4 * 1024 * 1024 : 8 * 1024 * 1024,
    );
    _streamIds[torrentId] = stream.id;
    _streamUrls[torrentId] = Uri.parse(stream.url);
    _startStateSaveTimer();
    return TorrentPlaybackStream(
      id: '${stream.id}',
      uri: Uri.parse(stream.url),
      file: file,
    );
  }

  @override
  Future<void> stop(TorrentHandle handle, {bool deleteFiles = false}) async {
    final id = _id(handle);
    for (final waiter in _metadataWaiters.remove(id) ?? <Completer<void>>{}) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('Source preparation canceled'));
      }
    }
    // Save before pausing/removing: resume data must be captured while the
    // handle and its piece map are still valid.
    _saveTorrentState(id);
    _native.stopAllStreamsForTorrent(id);
    if (deleteFiles) {
      _native.removeTorrent(id, deleteFiles: true);
      _retainedTorrents.removeWhere((_, torrentId) => torrentId == id);
      _stateDirectories.remove(id);
    } else {
      // Keeping the handle avoids a second metadata exchange and preserves the
      // verified piece map for replay during this app session.
      _native.pauseTorrent(id);
    }
    _streamIds.remove(id);
    _streamUrls.remove(id);
    if (!deleteFiles) {
      _idleRelease.remove(id)?.cancel();
      _idleRelease[id] = Timer(
        const Duration(seconds: 30),
        () => unawaited(releaseInactive(handle)),
      );
      while (_idleRelease.length > 2) {
        await releaseInactive(TorrentHandle('${_idleRelease.keys.first}'));
      }
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _initializing;
    } catch (_) {}
    if (_engine == null) return;
    for (final waiters in _metadataWaiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('Engine stopped'));
        }
      }
    }
    _metadataWaiters.clear();
    for (final timer in _idleRelease.values) {
      timer.cancel();
    }
    _idleRelease.clear();
    _stateSaveTimer?.cancel();
    _stateSaveTimer = null;
    for (final id in _stateDirectories.keys.toList()) {
      _saveTorrentState(id);
    }
    await _native.dispose();
    _engine = null;
    _retainedTorrents.clear();
    _addFlights.clear();
    _stateDirectories.clear();
    _streamIds.clear();
    _streamUrls.clear();
    _sessionDirectory = null;
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
