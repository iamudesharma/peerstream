import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:media_forge/media_forge.dart' show RustLib;
import 'package:media_forge_player/media_forge_player.dart'
    show
        MediaForgeDecodeResolution,
        MediaForgeMedia,
        MediaForgeNetworkProfile,
        MediaForgePlayerConfiguration;

import '../../models/media_item.dart';
import '../../models/torrent_models.dart';
import '../../models/watch_progress.dart';
import '../../services/settings/settings_store.dart';

/// Playback engine selection. Internal only for now; the user-facing
/// setting remains the `Use MediaForge Player` boolean.
enum PlayerBackend {
  defaultPlayer,
  mediaForge,
}

/// Single place where the backend is chosen. `true` selects the
/// experimental MediaForge engine, `false` keeps the existing player
/// with zero behavior changes.
PlayerBackend resolveBackend(AppSettings settings) =>
    settings.useMediaForgePlayer
        ? PlayerBackend.mediaForge
        : PlayerBackend.defaultPlayer;

/// Freezes the backend for one playback session. The first resolved value
/// wins; later setting changes apply to the next media open, never by
/// hot-swapping engines mid-session. Pure for tests.
PlayerBackend freezeBackendChoice(
  PlayerBackend? frozen,
  PlayerBackend resolved,
) => frozen ?? resolved;

/// Session-level playback logging. Distinguishes requested vs active
/// backend so fallback is visible in bug reports. No per-frame logging.
void logPlaybackBackend({
  required PlayerBackend requested,
  required PlayerBackend active,
  String? reason,
  String? source,
}) {
  debugPrint('[Playback] Requested backend: ${_label(requested)}');
  debugPrint('[Playback] Active backend: ${_label(active)}');
  if (reason != null) debugPrint('[Playback] Fallback reason: $reason');
  if (source != null) {
    debugPrint('[Playback] Opening MediaForge network source: $source');
  }
}

String _label(PlayerBackend backend) => switch (backend) {
  PlayerBackend.defaultPlayer => 'Default',
  PlayerBackend.mediaForge => 'MediaForge',
};

/// MediaForge read timeout for torrent-backed localhost streams.
///
/// Local servers may legitimately stall waiting for a piece; this matches
/// the native piece-wait budget so both layers abandon together.
const mediaForgeTorrentTimeout = Duration(seconds: 60);

/// MediaForge read timeout for normal remote HTTP(S) streams.
const mediaForgeDirectTimeout = Duration(seconds: 30);

/// PeerStream-side source classification for MediaForge opens.
///
/// Decides which network profile/timeouts to request. File URIs open as
/// local files; loopback HTTP(S) is PeerStream's torrent server;
/// everything else is a direct remote stream.
enum MediaForgeSourceType {
  file,
  torrentLocalhost,
  directHttp,
}

/// Classifies [uri] without touching MediaForge internals. Pure for tests.
MediaForgeSourceType classifyMediaForgeSource(Uri uri) {
  if (uri.scheme == 'file') return MediaForgeSourceType.file;
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    final host = uri.host.toLowerCase();
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return MediaForgeSourceType.torrentLocalhost;
    }
  }
  return MediaForgeSourceType.directHttp;
}

String mediaForgeSourceTypeLabel(MediaForgeSourceType type) => switch (type) {
  MediaForgeSourceType.file => 'file',
  MediaForgeSourceType.torrentLocalhost => 'torrent_localhost',
  MediaForgeSourceType.directHttp => 'direct_http',
};

/// Selects the MediaForge network profile for [uri].
///
/// * torrent localhost → torrent-localhost profile (longer streaming
///   timeout, seekable Range assumptions, reconnect enabled)
/// * direct HTTP(S) → direct-HTTP profile (caller headers preserved by the
///   media layer; reconnect preference preserved, default on)
/// * file → cached/file profile (no network options)
///
/// Explicit [timeout]/[reconnect] override the per-type defaults. Pure for
/// tests; the engine still owns the actual reads.
MediaForgeNetworkProfile mediaForgeNetworkProfileForUri(
  Uri uri, {
  Duration? timeout,
  bool? reconnect,
}) {
  switch (classifyMediaForgeSource(uri)) {
    case MediaForgeSourceType.file:
      return const MediaForgeNetworkProfile.cachedFile();
    case MediaForgeSourceType.torrentLocalhost:
      return MediaForgeNetworkProfile.torrentLocalhost(
        timeout: timeout ?? mediaForgeTorrentTimeout,
        reconnect: reconnect ?? true,
      );
    case MediaForgeSourceType.directHttp:
      return MediaForgeNetworkProfile.directHttp(
        timeout: timeout ?? mediaForgeDirectTimeout,
        reconnect: reconnect ?? true,
      );
  }
}

/// Builds the MediaForge player configuration for [uri].
///
/// Always requests native source decode resolution; the network profile is
/// the per-source selection from [mediaForgeNetworkProfileForUri].
/// Pure for tests.
MediaForgePlayerConfiguration buildMediaForgeConfigurationForUri(
  Uri uri, {
  Duration? timeout,
  bool? reconnect,
}) {
  return MediaForgePlayerConfiguration(
    decodeResolution: MediaForgeDecodeResolution.native,
    networkProfile: mediaForgeNetworkProfileForUri(
      uri,
      timeout: timeout,
      reconnect: reconnect,
    ),
  );
}

/// Base configuration used when the controller is created before the first
/// playback URI is known. Native decode resolution; per-source network
/// profiles are selected on every open via [buildMediaForgeMedia] timeouts
/// and reported via [mediaForgeNetworkProfileForUri].
const mediaForgeBaseConfiguration = MediaForgePlayerConfiguration(
  decodeResolution: MediaForgeDecodeResolution.native,
);

/// Builds the MediaForge source for a resolved playback URI.
///
/// File URIs (verified cache hits) open as local files; loopback HTTP(S)
/// (PeerStream torrent servers) carries the longer streaming timeout with
/// reconnect on; direct remote streams keep the shorter timeout. Headers
/// and the supplied user agent are always preserved so direct/provider
/// streams behave like the default player. Pure for tests.
MediaForgeMedia buildMediaForgeMedia({
  required Uri uri,
  Map<String, String> headers = const {},
  String userAgent = '',
  Duration? timeout,
  bool reconnect = true,
}) {
  if (uri.scheme == 'file') {
    return MediaForgeMedia.file(uri.toFilePath());
  }
  final type = classifyMediaForgeSource(uri);
  return MediaForgeMedia.network(
    uri.toString(),
    headers: headers,
    userAgent: userAgent,
    timeout:
        timeout ??
        (type == MediaForgeSourceType.torrentLocalhost
            ? mediaForgeTorrentTimeout
            : mediaForgeDirectTimeout),
    reconnect: reconnect,
  );
}

/// Session-level fallback position: preserve the MediaForge position when
/// available, else the explicit start, else the route resume value.
/// Never mutates settings; pure for tests.
int? resolveFallbackResumeMs({
  required int controllerPositionMs,
  int? explicitStartMs,
  int? widgetResumeMs,
}) {
  if (controllerPositionMs > 0) return controllerPositionMs;
  return explicitStartMs ?? widgetResumeMs;
}

/// Builds the watch-history entry for a persist tick.
///
/// Returns `null` when there is nothing worth recording yet
/// (`positionMs <= 0`). Finished/trivial filtering stays with the caller
/// (remove vs skip), which needs no provider access either. Pure for
/// tests — the player screens resolve title/artwork from their cached
/// snapshots so persisting from dispose() never touches `ref`.
WatchEntry? buildWatchPersistEntry({
  required int positionMs,
  required int durationMs,
  required String key,
  required MediaRef media,
  required String title,
  String? posterPath,
  String? backdropPath,
  required int? season,
  required int? episode,
  required String sourceId,
  required String providerName,
  required String sourceUri,
  required String inputType,
}) {
  if (positionMs <= 0) return null;
  return WatchEntry(
    key: key,
    media: media,
    title: title,
    posterPath: posterPath,
    backdropPath: backdropPath,
    season: season,
    episode: episode,
    sourceId: sourceId,
    providerName: providerName,
    sourceUri: sourceUri,
    inputType: inputType,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: DateTime.now(),
  );
}

/// Playback stages the MediaForge UI distinguishes.
///
/// `firstFramePresented` is a real stage: nothing is visually ready until
/// the player confirms the first frame reached the display.
enum MediaForgePlaybackStage {
  opening,
  buffering,
  firstFramePresented,
  playing,
  seeking,
  rebuffering,
  ended,
  error,
}

/// Resolves the display stage from player state plus the latest seek
/// generation. Stale seeks never surface: [hasPendingSeek] must reflect
/// only the newest generation (see [MediaForgeSeekCoordinator]).
/// Pure for tests.
MediaForgePlaybackStage resolveMediaForgeStage({
  required bool hasError,
  required bool isCompleted,
  required bool isInitialized,
  required bool firstFramePresented,
  required bool isPlaying,
  required bool isBuffering,
  required bool hasPendingSeek,
}) {
  if (hasError) return MediaForgePlaybackStage.error;
  if (isCompleted) return MediaForgePlaybackStage.ended;
  if (hasPendingSeek) return MediaForgePlaybackStage.seeking;
  if (!isInitialized) return MediaForgePlaybackStage.opening;
  if (!firstFramePresented) return MediaForgePlaybackStage.buffering;
  if (isBuffering) return MediaForgePlaybackStage.rebuffering;
  if (isPlaying) return MediaForgePlaybackStage.playing;
  return MediaForgePlaybackStage.firstFramePresented;
}

/// Visual readiness: non-zero position is NOT evidence of display.
/// Only the player's first-frame confirmation counts. Pure for tests.
bool isMediaForgeVisuallyReady({
  required bool isInitialized,
  required bool firstFramePresented,
  required bool hasError,
}) => isInitialized && firstFramePresented && !hasError;

/// Tracks MediaForge seek generations so only the latest seek drives UI,
/// service, and history state. Stale completions are rejected and must
/// never overwrite a newer seek. Pure for tests.
class MediaForgeSeekCoordinator {
  int _latestStarted = -1;
  int _latestSettled = -1;

  int get latestStarted => _latestStarted;
  int get latestSettled => _latestSettled;
  bool get hasPendingSeek => _latestSettled != _latestStarted;

  void onSeekStarted(int generation) {
    if (generation > _latestStarted) _latestStarted = generation;
  }

  /// True only when [generation] is the newest started seek that has not
  /// settled yet.
  bool shouldApplySettled(int generation) =>
      generation == _latestStarted && generation != _latestSettled;

  void onSeekSettled(int generation) {
    if (generation == _latestStarted) _latestSettled = generation;
  }

  /// Voids a failed seek so a stuck seeking state can never latch forever.
  ///
  /// Only applies when [generation] is still the newest started seek; a
  /// superseding seek owns the state instead. Late completions for a voided
  /// generation are rejected by [shouldApplySettled], exactly like stale
  /// ones. Pure for tests.
  void onSeekFailed(int generation) {
    if (generation == _latestStarted) _latestSettled = generation;
  }
}

/// Resume-seek retry budget for the experimental player.
///
/// A single post-open seek is the flakiest call in torrent playback (no
/// frames yet, keyframe gate, demuxer still probing), so resume seeks retry
/// with backoff until they land, are superseded by a newer seek, or exhaust
/// the budget — mirroring the default player's settle loop. Pure for tests.
const mediaForgeResumeSeekMaxAttempts = 8;

/// How long one attempt waits for its settle event before retrying.
const mediaForgeResumeSeekSettleTimeout = Duration(seconds: 5);

/// Linear backoff between resume attempts, capped so the worst case stays
/// near the default player's ~45s settle window. Pure for tests.
Duration mediaForgeResumeSeekDelay(int attempt) {
  final ms = 500 * attempt;
  return Duration(milliseconds: ms.clamp(500, 2000));
}

/// Whether [position] counts as having reached [target].
///
/// Same asymmetric window the default player settles with: a small tolerance
/// behind the target, generous ahead of it. Pure for tests.
bool mediaForgeResumeSeekLanded({
  required Duration position,
  required Duration target,
}) {
  return position + const Duration(seconds: 3) >= target &&
      position <= target + const Duration(seconds: 30);
}

/// Resume query value for opening [source] from saved history, if any.
///
/// Returns the saved position in ms, or `null` when there is nothing worth
/// resuming. Trivial/finished filtering stays with the player screens.
/// Pure for tests.
int? resumeMsForSource({
  required TorrentSource source,
  required List<WatchEntry>? history,
}) {
  final entries = history;
  if (entries == null || entries.isEmpty) return null;
  final key = watchKey(
    source.content,
    source.seasonNumber,
    source.episodeNumber,
  );
  for (final entry in entries) {
    if (entry.key == key) {
      return entry.positionMs > 0 ? entry.positionMs : null;
    }
  }
  return null;
}

/// Performs one resume-seek attempt. Must throw on failure so the driver
/// can back off and retry; must bump the generation observed via
/// [MediaForgeResumeSeekDriver.currentGeneration] exactly once per attempt
/// that reports started (mirrors `MediaForgePlayerController.seek`).
typedef MediaForgeResumeSeekAttempt = Future<void> Function(Duration target);

/// Outcome of one settle wait inside [MediaForgeResumeSeekDriver].
enum _ResumeWaitOutcome { settled, superseded, timedOut, disposed }

/// Drives a resume seek to [target] until it lands, is superseded by a
/// newer seek, or exhausts its budget.
///
/// All player access flows through callbacks so the policy is unit-testable
/// and screens stay thin. Returns `true` when driving should stop because
/// the target was reached or the state was legitimately handed off
/// (superseded/cancelled/torn down); `false` only when the budget ran out
/// with the session still ours.
class MediaForgeResumeSeekDriver {
  MediaForgeResumeSeekDriver({
    this.maxAttempts = mediaForgeResumeSeekMaxAttempts,
    this.settleTimeout = mediaForgeResumeSeekSettleTimeout,
    this.pollInterval = const Duration(milliseconds: 250),
    Future<void> Function(Duration delay)? delayFn,
  }) : _delayFn = delayFn ?? Future.delayed;

  final int maxAttempts;
  final Duration settleTimeout;
  final Duration pollInterval;
  final Future<void> Function(Duration delay) _delayFn;

  int _runId = 0;

  /// Cancels the in-flight drive, if any. The loop exits at the next
  /// checkpoint without touching player state.
  void cancel() => _runId++;

  Future<bool> drive({
    required String reason,
    required Duration target,
    required MediaForgeResumeSeekAttempt seek,
    required int Function() currentGeneration,
    required int Function() latestStarted,
    required int Function() latestSettled,
    required Duration Function() position,
    required bool Function() isCurrent,
    required void Function(int generation) onAttemptFailed,
  }) async {
    final run = ++_runId;
    bool current() => isCurrent() && run == _runId;
    var attempt = 0;
    while (current()) {
      if (mediaForgeResumeSeekLanded(
        position: position(),
        target: target,
      )) {
        return true;
      }
      if (++attempt > maxAttempts) {
        debugPrint(
          '[Playback] MediaForge resume seek gave up '
          '($reason) target=${target.inMilliseconds}ms after $maxAttempts attempts',
        );
        return false;
      }
      // Generation before the attempt: a real controller bumps it exactly
      // once per attempt that reports started, so `genBefore + 1` identifies
      // this attempt's generation below.
      final genBefore = currentGeneration();
      final startedBefore = latestStarted();
      try {
        await seek(target);
      } catch (error) {
        if (!current()) return false;
        // Flush event delivery so an emitted started is observable before
        // deciding whether this attempt owns any state.
        await _delayFn(Duration.zero);
        if (!current()) return false;
        final nowStarted = latestStarted();
        if (nowStarted != startedBefore && nowStarted == genBefore + 1) {
          // Our attempt reported started, then failed: void it so seeking
          // can never latch forever and history saves recover.
          onAttemptFailed(nowStarted);
        } else if (nowStarted != startedBefore) {
          // A newer seek owns the state now; stop driving the old target.
          return true;
        }
        // Else: silent no-op (nothing emitted); back off and retry bounded.
        debugPrint(
          '[Playback] MediaForge resume seek attempt $attempt/$maxAttempts '
          'failed ($reason): $error',
        );
        await _delayFn(mediaForgeResumeSeekDelay(attempt));
        continue;
      }
      if (!current()) return false;
      switch (await _awaitSettled(
        current: current,
        watchGeneration: currentGeneration(),
        target: target,
        latestStarted: latestStarted,
        latestSettled: latestSettled,
        position: position,
      )) {
        case _ResumeWaitOutcome.settled:
          return true;
        case _ResumeWaitOutcome.superseded:
        case _ResumeWaitOutcome.disposed:
          return true;
        case _ResumeWaitOutcome.timedOut:
          debugPrint(
            '[Playback] MediaForge resume seek attempt $attempt/$maxAttempts '
            'unsettled ($reason), retrying',
          );
      }
    }
    return false;
  }

  Future<_ResumeWaitOutcome> _awaitSettled({
    required bool Function() current,
    required int watchGeneration,
    required Duration target,
    required int Function() latestStarted,
    required int Function() latestSettled,
    required Duration Function() position,
  }) async {
    final deadline = DateTime.now().add(settleTimeout);
    while (current()) {
      // A newer seek owns the state; stop driving the old target.
      if (latestStarted() != watchGeneration) {
        return _ResumeWaitOutcome.superseded;
      }
      if (latestSettled() == watchGeneration) {
        return _ResumeWaitOutcome.settled;
      }
      if (mediaForgeResumeSeekLanded(
        position: position(),
        target: target,
      )) {
        return _ResumeWaitOutcome.settled;
      }
      if (!DateTime.now().isBefore(deadline)) {
        return _ResumeWaitOutcome.timedOut;
      }
      await _delayFn(pollInterval);
    }
    return _ResumeWaitOutcome.disposed;
  }
}

/// Lifecycle forwarding decision for the MediaForge controller.
///
/// Background states suspend the frame pump, diagnostics, subtitle polling,
/// and audio without disposing the session; foreground resumes the same
/// session. The default player never consults this. Pure for tests.
MediaForgeLifecycleAction mediaForgeLifecycleAction(AppLifecycleState state) {
  return state == AppLifecycleState.resumed
      ? MediaForgeLifecycleAction.resume
      : MediaForgeLifecycleAction.suspend;
}

enum MediaForgeLifecycleAction { suspend, resume }

/// Deterministic teardown order. The player (and its textures/native
/// resources) is always released before the owned torrent session stops,
/// and the route leaves last:
///
/// stop UI interaction → release player → release textures/native →
/// stop torrent session → leave route.
///
/// UI interaction and route steps are owned by the caller; this helper
/// enforces the awaited middle. [stopTorrent] runs even when
/// [releasePlayer] throws so native resources are never abandoned while
/// the server keeps serving a dead reader (or vice versa).
Future<void> runMediaForgeTeardown({
  required Future<void> Function() releasePlayer,
  required Future<void> Function() stopTorrent,
}) async {
  try {
    await releasePlayer();
  } finally {
    await stopTorrent();
  }
}

/// Benchmark payload keys. Torrent/network waits stay separate from
/// decoder/render latency: `tapToFirstFrameMs` covers session claim to
/// first frame (torrent + open), while `firstFrameLatencyMs` is the
/// player-reported open-to-present time (decoder/render only).
Map<String, dynamic> buildMediaForgeBenchmarkPayload({
  required PlayerBackend requested,
  required PlayerBackend active,
  required MediaForgeSourceType sourceType,
  int? tapToFirstFrameMs,
  int? firstFrameLatencyMs,
  int? lastSeekLatencyMs,
  int? lastSeekGeneration,
  double? presentedFps,
  double? decodedFps,
  int? droppedFrames,
  int? avDriftMs,
  String? activeDecoder,
  String? renderingPath,
  int? rebufferEvents,
  int? stallEvents,
  int? subtitleCuesPending,
  int? positionMs,
  String? note,
}) {
  final payload = <String, dynamic>{
    'requestedBackend': _label(requested),
    'activeBackend': _label(active),
    'sourceType': mediaForgeSourceTypeLabel(sourceType),
  };
  void setNum(String key, num? value) {
    if (value != null) payload[key] = value;
  }

  void setText(String key, String? value) {
    if (value != null) payload[key] = value;
  }

  setNum('tapToFirstFrameMs', tapToFirstFrameMs);
  setNum('firstFrameLatencyMs', firstFrameLatencyMs);
  setNum('lastSeekLatencyMs', lastSeekLatencyMs);
  if (lastSeekGeneration != null && lastSeekGeneration >= 0) {
    payload['lastSeekGeneration'] = lastSeekGeneration;
  }
  setNum('presentedFps', presentedFps);
  setNum('decodedFps', decodedFps);
  setNum('droppedFrames', droppedFrames);
  setNum('avDriftMs', avDriftMs);
  setText('activeDecoder', activeDecoder);
  setText('renderingPath', renderingPath);
  setNum('rebufferEvents', rebufferEvents);
  setNum('stallEvents', stallEvents);
  setNum('subtitleCuesPending', subtitleCuesPending);
  setNum('positionMs', positionMs);
  setText('note', note);
  return payload;
}

/// Session-level benchmark logging. Called on transitions (open,
/// first frame, seek settled, fallback, teardown summary) — never
/// per frame. Numbers are only meaningful on physical devices.
void logMediaForgeBenchmark(Map<String, dynamic> payload) {
  debugPrint('[Playback][Benchmark] $payload');
}

/// Memoized Rust runtime init. Initialized at most once per process and
/// only when MediaForge is actually selected.
class MediaForgeRuntime {
  MediaForgeRuntime._();

  static Future<void>? _initFuture;

  @visibleForTesting
  static void resetForTest() => _initFuture = null;

  static Future<void> ensureInitialized() {
    return _initFuture ??= _init();
  }

  static Future<void> _init() async {
    debugPrint('[Playback] Initializing MediaForge runtime');
    await RustLib.init();
  }
}
