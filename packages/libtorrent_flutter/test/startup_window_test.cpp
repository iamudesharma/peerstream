#include "../src/startup_window.h"
#include <cassert>

int main() {
    constexpr int MiB = 1024 * 1024;
    // Regression: an 8 MiB torrent used to queue 128 MiB before its header
    // could be parsed, starving a demanded MP4 tail behind forward deadlines.
    assert(startup_window_pieces(16, 8 * MiB, 823, true) == 1);
    assert(startup_window_pieces(64, MiB / 2, 4000, true) == 4);
    assert(startup_window_pieces(64, MiB / 4, 4000, true) == 8);
    // Full throughput window resumes after container discovery, including
    // cold resume targets and seeks outside the header region.
    assert(startup_window_pieces(16, 8 * MiB, 823, false) == 16);
    assert(startup_window_pieces(64, MiB / 2, 4000, false) == 64);
    assert(startup_window_pieces(64, MiB / 4, 2, true) == 2);
    assert(startup_window_pieces(64, MiB, 0, true) == 0);
    assert(container_probe_pieces(8 * MiB, 20) == 1);
    assert(container_probe_pieces(0, 20) == 1);
    assert(speculative_tail_pieces(MiB / 8, 1000) == 4);
    assert(speculative_tail_pieces(8 * MiB, 823) == 1);
    assert(speculative_tail_pieces(MiB / 8, 2) == 2);
}
