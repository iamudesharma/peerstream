/// Adaptive piece scheduler policy shared by the Dart layer and the native
/// `torrent_bridge.cpp` streaming engine.
///
/// The localhost HTTP Range server is player-independent: it serves whatever
/// byte range the player asks for. This policy maps those byte ranges to
/// torrent pieces and sizes tiered priority windows so the swarm works on
/// what playback needs *now* first:
///
/// - CRITICAL: the piece(s) containing the current Range cursor. Deadline 0,
///   top priority. Playback is blocked on these.
/// - URGENT: the next few seconds of media. High priority, tightly staggered
///   deadlines. Keeps the demuxer fed through VBR spikes.
/// - PREFETCH: further ahead up to the adaptive forward target. Normal-high
///   priority, later deadlines. Keeps peer request queues full so peers never
///   idle between piece completions.
/// - BACKGROUND: everything else. No deadline, background priority.
///
/// Windows are sized in *seconds of video* (bytes / bitrate), not fixed piece
/// counts, so a 256KB-piece episode and a 4MB-piece 4K movie get different
/// piece windows for the same time horizon. Piece size, file bitrate/size,
/// swarm download speed, and peer count all feed the sizing when available.
///
/// The C++ `StreamScheduler` / `serve_range` implementation follows the same
/// tier boundaries and clamps; this file is the testable contract for that
/// behavior (`flutter test` covers it without a native binary).
library;

/// Priority tier for a piece relative to the current playback cursor.
enum PieceTier {
  /// Currently blocked on: the piece containing the Range cursor plus a tiny
  /// tolerance for keyframe/VBR drift.
  critical,

  /// Next seconds of playback. Must arrive before its playback time.
  urgent,

  /// Further ahead up to the adaptive forward target. Keeps peers busy.
  prefetch,

  /// Outside the forward window. Background / normal priority.
  background,
}

/// Tiered forward window around [targetPiece], clamped to
/// [[startPiece], [endPiece]].
class PieceWindow {
  const PieceWindow({
    required this.startPiece,
    required this.criticalEnd,
    required this.urgentEnd,
    required this.endPiece,
  });

  /// First piece in the window (may sit slightly behind [targetPiece] for
  /// keyframe/VBR tolerance).
  final int startPiece;

  /// Last CRITICAL piece (inclusive).
  final int criticalEnd;

  /// Last URGENT piece (inclusive). Everything after this up to [endPiece]
  /// is PREFETCH.
  final int urgentEnd;

  /// Last piece in the window (inclusive).
  final int endPiece;

  int get totalPieces => endPiece >= startPiece ? endPiece - startPiece + 1 : 0;

  PieceTier tierOf(int piece) {
    if (piece < startPiece || piece > endPiece) return PieceTier.background;
    if (piece <= criticalEnd) return PieceTier.critical;
    if (piece <= urgentEnd) return PieceTier.urgent;
    return PieceTier.prefetch;
  }
}

/// Maps a byte range of the selected file to torrent piece indices.
///
/// [rangeStart]/[rangeEnd] are file-relative byte offsets (inclusive).
/// [fileOffset] is the file's byte offset inside the torrent, [pieceLength]
/// the torrent piece size, and [[startPiece], [endPiece]] the file's piece
/// span. Returns `(startPiece, endPiece)` clamped into the file span.
({int startPiece, int endPiece}) byteRangeToPieces({
  required int rangeStart,
  required int rangeEnd,
  required int fileOffset,
  required int pieceLength,
  required int startPiece,
  required int endPiece,
}) {
  if (pieceLength <= 0 || endPiece < startPiece) {
    return (startPiece: startPiece, endPiece: startPiece);
  }
  var lo = (fileOffset + rangeStart) ~/ pieceLength;
  var hi = (fileOffset + rangeEnd) ~/ pieceLength;
  lo = lo.clamp(startPiece, endPiece);
  hi = hi.clamp(startPiece, endPiece);
  if (hi < lo) hi = lo;
  return (startPiece: lo, endPiece: hi);
}

/// Estimates media bitrate in bytes/sec.
///
/// Prefers the observed [durationMs] when valid, otherwise falls back to a
/// size-based duration guess (episode vs movie vs large 4K) so tiny and huge
/// files do not share one hardcoded bitrate. Returns 0 when [fileSize] is
/// unknown.
int estimateBitrateBps({required int fileSize, int? durationMs}) {
  if (fileSize <= 0) return 0;
  if (durationMs != null && durationMs > 0) {
    return (fileSize * 1000 / durationMs).round();
  }
  final double durationGuess;
  if (fileSize < 400 * 1024 * 1024) {
    durationGuess = 3600; // episode
  } else if (fileSize < 1024 * 1024 * 1024) {
    durationGuess = 5400; // 1.5h
  } else if (fileSize < 3 * 1024 * 1024 * 1024) {
    durationGuess = 6600;
  } else if (fileSize < 8 * 1024 * 1024 * 1024) {
    durationGuess = 7200;
  } else {
    durationGuess = 9000;
  }
  return (fileSize / durationGuess).round();
}

/// Adaptive forward-target in seconds of video.
///
/// A swarm comfortably outrunning the media needs a shallow buffer; a swarm
/// barely keeping up (or a thin swarm with few peers) needs a deeper safety
/// margin. Mirrors `adaptiveWindowBytes` in `torrent_engine.dart` and the
/// native `adaptive_window_pieces`.
double adaptiveForwardSeconds({
  required int bitrateBps,
  int bufferedAheadMs = 0,
  int downloadRateBps = 0,
  int peers = 0,
}) {
  if (bitrateBps <= 0) return 25;
  final bufferedSeconds = bufferedAheadMs / 1000.0;
  double seconds;
  if (bufferedSeconds >= 60) {
    seconds = 15;
  } else if (bufferedSeconds >= 30) {
    seconds = 25;
  } else if (bufferedSeconds >= 10) {
    seconds = 40;
  } else {
    seconds = 60;
  }
  if (downloadRateBps > 0) {
    if (downloadRateBps > bitrateBps * 2) {
      seconds *= 0.6;
    } else if (downloadRateBps < bitrateBps * 1.2) {
      seconds *= 1.5;
    }
  }
  if (peers > 0 && peers < 4) seconds *= 1.3;
  return seconds.clamp(10, 90);
}

/// Minimum parallel request depth for a cold or stalled playback window.
///
/// A large torrent piece has to be completely verified before libtorrent can
/// expose it to the HTTP server. A fixed four-piece floor is therefore too
/// shallow for, for example, 8 MiB pieces: one unavailable leading piece can
/// leave every peer request focused on just a few large hashes. Scale the
/// cold floor with piece size (4 for sub-2 MiB pieces, 8 for 4 MiB, 16 for
/// 8 MiB), then return to the normal four-piece floor once data is flowing or
/// a real buffer exists. This mirrors native `pipeline_floor_pieces`.
int adaptivePipelineFloorPieces({
  required int pieceLength,
  int bufferedAheadMs = 0,
  int downloadRateBps = 0,
}) {
  if (pieceLength <= 0 || bufferedAheadMs > 1000 || downloadRateBps > 0) {
    return 4;
  }
  const mib = 1024 * 1024;
  final mibPieces = (pieceLength + mib - 1) ~/ mib;
  return (mibPieces * 2).clamp(4, 16);
}

/// Total adaptive lookahead in pieces for [targetPiece].
///
/// Sized from [adaptiveForwardSeconds] converted through [bitrateBps] and
/// [pieceLength], with a piece-size-aware cold-start floor and a 64-piece
/// ceiling. Never exceeds the file span.
int adaptiveLookaheadPieces({
  required int targetPiece,
  required int startPiece,
  required int endPiece,
  required int pieceLength,
  required int bitrateBps,
  int bufferedAheadMs = 0,
  int downloadRateBps = 0,
  int peers = 0,
}) {
  if (pieceLength <= 0 || endPiece < targetPiece) return 0;
  final seconds = adaptiveForwardSeconds(
    bitrateBps: bitrateBps,
    bufferedAheadMs: bufferedAheadMs,
    downloadRateBps: downloadRateBps,
    peers: peers,
  );
  final effectiveBitrate = bitrateBps > 0 ? bitrateBps : 625000;
  var pieces = ((effectiveBitrate * seconds) / pieceLength).round();
  pieces = pieces.clamp(
    adaptivePipelineFloorPieces(
      pieceLength: pieceLength,
      bufferedAheadMs: bufferedAheadMs,
      downloadRateBps: downloadRateBps,
    ),
    64,
  );
  final remaining = endPiece - targetPiece + 1;
  if (pieces > remaining) pieces = remaining;
  return pieces;
}

/// Builds the tiered window around [targetPiece].
///
/// - CRITICAL covers ~2s of video (at least 1 piece, at most 3) — the bytes
///   the player is blocked on right now.
/// - URGENT covers the next ~8s of video (at least 2 pieces).
/// - PREFETCH extends to the adaptive forward target.
/// - No missing pieces behind the target are requested speculatively. The
///   native trailing cache covers small rewinds; an actual backwards Range is
///   immediately promoted when the player asks for it. This prevents an old
///   playback location from competing with a seek target.
PieceWindow schedulerTiers({
  required int targetPiece,
  required int startPiece,
  required int endPiece,
  required int pieceLength,
  required int bitrateBps,
  int bufferedAheadMs = 0,
  int downloadRateBps = 0,
  int peers = 0,
}) {
  final clampedTarget = targetPiece.clamp(startPiece, endPiece);
  final effectiveBitrate = bitrateBps > 0 ? bitrateBps : 625000;
  final safePieceLength = pieceLength > 0 ? pieceLength : 256 * 1024;

  final total = adaptiveLookaheadPieces(
    targetPiece: clampedTarget,
    startPiece: startPiece,
    endPiece: endPiece,
    pieceLength: safePieceLength,
    bitrateBps: effectiveBitrate,
    bufferedAheadMs: bufferedAheadMs,
    downloadRateBps: downloadRateBps,
    peers: peers,
  );
  // Range requests are the source of truth. Keep already-read pieces in the
  // trailing cache, but do not spend swarm bandwidth fetching bytes behind
  // the cursor just in case a demuxer needs them.
  final start = clampedTarget;

  // CRITICAL: ~2s of video from the target forward.
  var criticalCount = ((effectiveBitrate * 2) / safePieceLength).ceil();
  criticalCount = criticalCount.clamp(1, 3);
  var criticalEnd = clampedTarget + criticalCount - 1;

  // URGENT: ~8s of video from the target forward (at least 2 pieces).
  var urgentCount = ((effectiveBitrate * 8) / safePieceLength).ceil();
  if (urgentCount < 2) urgentCount = 2;
  var urgentEnd = clampedTarget + urgentCount - 1;

  var end = clampedTarget + total - 1;
  if (end > endPiece) end = endPiece;
  if (criticalEnd > end) criticalEnd = end;
  if (urgentEnd > end) urgentEnd = end;
  if (urgentEnd < criticalEnd) urgentEnd = criticalEnd;

  return PieceWindow(
    startPiece: start,
    criticalEnd: criticalEnd,
    urgentEnd: urgentEnd,
    endPiece: end,
  );
}

/// Whether an incoming playback Range should replace the active priority
/// window.
///
/// The first player Range must expand the startup window even when its target
/// piece is already verified locally. Afterwards the window rolls forward as
/// the cursor reaches its urgent boundary. A seek always replaces the prior
/// work immediately. This is deliberately independent of a player's request
/// chunk size: a single open-ended request and many small 206 requests follow
/// the same policy.
bool shouldRefreshPlaybackWindow({
  required int targetPiece,
  required PieceWindow activeWindow,
  int? lastPlaybackTargetPiece,
  bool isSeek = false,
}) {
  if (isSeek || lastPlaybackTargetPiece == null) return true;
  return targetPiece < activeWindow.startPiece ||
      targetPiece >= activeWindow.urgentEnd ||
      targetPiece > activeWindow.endPiece;
}

/// Whether a startup Range belongs to media_kit's container inspection while
/// a pre-open resume window is pending.
///
/// Players commonly request bytes at the file head (and then the tail) before
/// issuing the real Range at the restored position. Those head reads need
/// priority, but they must not cancel the already-dispatched resume pieces.
/// A request within the first two file pieces or at the pending target is a
/// bootstrap read; other Range changes remain real seeks. Mirrors native
/// `is_startup_resume_bootstrap_range`.
bool shouldPreserveStartupResumeWindow({
  required bool hasPendingResume,
  required int requestPiece,
  required int startPiece,
  required int resumeTargetPiece,
}) {
  if (!hasPendingResume) return false;
  return requestPiece <= startPiece + 1 ||
      (requestPiece - resumeTargetPiece).abs() <= 1;
}

/// Deadline stagger step in ms derived from the estimated piece playback
/// duration. Pieces should arrive before their playback time with the first
/// pieces urgent and later ones progressively later. Clamped so a slow swarm
/// still gets an aggressive early gradient and a fast one does not
/// over-stagger. Mirrors native `piece_deadline_step_ms`.
int pieceDeadlineStepMs({required int pieceLength, required int bitrateBps}) {
  final effectiveBitrate = bitrateBps > 1000 ? bitrateBps : 625000;
  final safePieceLength = pieceLength > 0 ? pieceLength : 256 * 1024;
  final pieceSeconds = safePieceLength / effectiveBitrate;
  final step = (pieceSeconds * 1000 * 0.35).round();
  return step.clamp(40, 250);
}

/// Number of head pieces covering container startup (file header / moov).
///
/// Kept small and adaptive: ~2s of video, at least 1 piece, at most 5.
/// Mirrors the native `critical_startup_pieces` computation.
int criticalStartupPieces({required int pieceLength, required int bitrateBps}) {
  if (pieceLength <= 0) return 2;
  final effectiveBitrate = bitrateBps > 0 ? bitrateBps : 625000;
  var bytes = (effectiveBitrate * 2).round();
  if (bytes < pieceLength) bytes = pieceLength;
  return (bytes / pieceLength).ceil().clamp(1, 5);
}
