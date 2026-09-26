#pragma once

#include <algorithm>
#include <cstdint>

// Container discovery cannot use minutes of forward media. Keep its immediate
// window within 2 MiB (or one indivisible torrent piece), then let the regular
// throughput-oriented scheduler take over once duration/container data arrives.
inline int container_probe_pieces(int piece_length, int remaining) {
    constexpr int64_t budget = 2 * 1024 * 1024;
    if (remaining <= 0) return 0;
    if (piece_length <= 0) return 1;
    const int pieces = static_cast<int>((budget + piece_length - 1) / piece_length);
    return std::clamp(pieces, 1, remaining);
}

inline int startup_window_pieces(int adaptive, int piece_length, int remaining,
                                bool discovering_container) {
    if (remaining <= 0) return 0;
    const int bounded = std::clamp(adaptive, 1, remaining);
    return discovering_container
        ? std::min(bounded, container_probe_pieces(piece_length, remaining))
        : bounded;
}

// Most trailing indexes fit in a small probe. Larger indexes are scheduled by
// the exact HTTP Range, without speculatively competing with the first frame.
inline int speculative_tail_pieces(int piece_length, int remaining) {
    constexpr int64_t budget = 512 * 1024;
    if (remaining <= 0) return 0;
    if (piece_length <= 0) return 1;
    return std::clamp(static_cast<int>((budget + piece_length - 1) / piece_length),
                      1, remaining);
}
