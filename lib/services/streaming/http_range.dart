/// HTTP Range request handling (RFC 9110 §14.2), mirroring
/// `torrent_bridge.cpp` handle_connection().
///
/// Out-of-bounds ranges return 416 instead of clamping into the file.
/// HEAD requests and container-metadata tail probes must not trigger
/// playback-seek behavior. Tested here in Dart so `flutter test` covers the
/// contract without a native binary; the C++ implementation follows the same
/// table.
class HttpRangeResult {
  const HttpRangeResult.satisfiable(this.start, this.end, {this.isPartial = true})
    : isSatisfiable = true;
  const HttpRangeResult.unsatisfiable()
    : isSatisfiable = false,
      start = 0,
      end = 0,
      isPartial = false;

  final bool isSatisfiable;
  final int start;
  final int end;
  final bool isPartial;

  int get contentLength => isSatisfiable ? end - start + 1 : 0;
}

class HttpRangeRequest {
  const HttpRangeRequest({this.start, this.end, this.isSuffix = false});
  final int? start;
  final int? end;
  final bool isSuffix;
}

/// Resolves [request] against a file of [fileSize] bytes.
///
/// - `null` request (no Range header) → full file 200.
/// - Suffix `bytes=-N` → last N bytes; N<=0 → 416.
/// - Open-ended `bytes=N-` → N..EOF; N>=size → 416.
/// - `bytes=N-M` with M>=size → clamp M (satisfiable prefix).
/// - Start beyond EOF or end<start → 416.
HttpRangeResult resolveHttpRange(HttpRangeRequest? request, int fileSize) {
  if (fileSize <= 0) return const HttpRangeResult.unsatisfiable();
  if (request == null) {
    return HttpRangeResult.satisfiable(0, fileSize - 1, isPartial: false);
  }
  if (request.isSuffix) {
    final suffix = request.end ?? 0;
    if (suffix <= 0) return const HttpRangeResult.unsatisfiable();
    var start = fileSize - suffix;
    if (start < 0) start = 0;
    return HttpRangeResult.satisfiable(start, fileSize - 1);
  }
  final start = request.start;
  final end = request.end;
  if (start != null && start >= fileSize) {
    return const HttpRangeResult.unsatisfiable();
  }
  if (start != null && end != null && end < start) {
    return const HttpRangeResult.unsatisfiable();
  }
  final resolvedStart = start ?? 0;
  var resolvedEnd = end ?? (fileSize - 1);
  if (resolvedEnd >= fileSize) resolvedEnd = fileSize - 1;
  if (resolvedEnd < resolvedStart) {
    return const HttpRangeResult.unsatisfiable();
  }
  final isPartial = start != null || request.isSuffix;
  return HttpRangeResult.satisfiable(
    resolvedStart,
    resolvedEnd,
    isPartial: isPartial,
  );
}

/// Whether [byteOffset] should trigger a playback seek versus being treated
/// as a metadata probe. HEAD requests and tail (container metadata) reads
/// never seek.
bool shouldTriggerSeek({
  required bool isHead,
  required int rangeStart,
  required int fileSize,
  required int pieceLength,
  required int currentHead,
}) {
  if (isHead) return false;
  final isTail = rangeStart > fileSize - pieceLength * 10;
  if (isTail) return false;
  if (currentHead <= 0) return false;
  return (rangeStart - currentHead).abs() > 65536;
}
