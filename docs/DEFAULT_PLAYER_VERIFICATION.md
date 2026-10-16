# Default player verification on macOS

## Current verification — 2026-10-16

The loaded bridge is **`bridge-1.9.10+lt2.1.1`**. The native engine and default
media_kit player remain the production defaults. Streaming preparation now keeps
metadata peers connected while blocking video piece requests until priorities
are installed. Cached service replay does not require its original metadata URL.

Twenty fresh-process local BitTorrent-wire trials per backend measured native
**1.917 s median / 2.912 s p95**, and service **2.419 s / 3.169 s**. All forty
started before full-file completion. The app-lifetime renderer is prepared before
source selection; its preparation time is recorded separately. Public legal cold
observations were **11.031 s** (target missed) and **6.435 s** (passed), without
source rediscovery or a full download.

The real multi-track fixture clicks audio/subtitle controls and checks native
`aid`/`sid`, menu bounds, fullscreen controls and subtitle rendering. Warm service
checks kill their owned helper, keep Retry visible, restart through the real cache
adapter and restore position with the metadata endpoint unavailable. Late events
from old media openings cannot consume the new resume request.

Flutter's **318 tests passed, one skipped**; the real full-volume case was separately
verified. Analysis and macOS debug builds passed. Native metadata-only, Range,
crash/reset, ten storage/transport fault checks and four TLS checks passed on
1.9.10. The cache/HTTP comparison completed 137 trials before a guarded-pump
timeout in the test harness; the requested 160-trial acceptance remains incomplete.
A separate three-block run passed all 24 trials after the harness change; results
are not pooled with the aborted acceptance run.
See [comparison records](benchmarks/controlled-matrix-macos-2026-10-16.json).

The latest native thirty-session/sixty-seek run passed its memory threshold at
**9.80%** growth; the service run completed but missed it at **10.08%** combined
app/helper growth. Rust remains experimental. The earlier two-hour decode soak
used bridge 1.9.8 and is not a soak of 1.9.10.

See [the implementation and evidence summary](UX_PERFORMANCE_ROADMAP.md) for exact
scopes, retained failures, the earlier history-isolation incident and remaining
signed-package, old-OS, visual-seek and background-permission gates.

## Historical verification — 2026-10-13

Verified on 2026-10-13 with `bridge-1.9.7+lt2.0.11`:

| Source | Visible first frame | Downloaded at that frame |
| --- | --- | --- |
| Generated local MP3/AC3 + subtitle fixture | 0.886 s | Local file |
| Cold Big Buck Bunny, fresh cache, run 1 | 5.156 s | 1,572,864 of 276,134,947 bytes |
| Cold Big Buck Bunny, fresh cache, run 2 | 9.935 s | 1,310,720 of 276,134,947 bytes |

Both cold runs started before the file was complete, without source rediscovery
or waiting for movie details. Native fullscreen checks verified switching both
audio tracks, both rendered subtitle streams, subtitles off and 1.5x speed.
These timings describe the tested source and current peers, not every torrent.

Validation: 265 Dart/widget tests passed, native control and cold-torrent tests
passed, analyzer clean, and the normal macOS debug app was rebuilt and relaunched.
At that time the additional web release check was blocked by direct imports of
`native_torrent_engine.dart` from both player screens, which pulled `dart:ffi` into
the browser compilation. Browser playback remains unsupported.

The native integration test mounts the real `DefaultPlayerScreen`, `media_kit`
player and video output. It opens original generated media with two audio streams
and two subtitle streams (MP3 stereo and AC3 surround audio), clicks the compact
controls in fullscreen, checks the native `aid`/`sid` properties, and checks that
the selected subtitle text renders.
Menus must stay within the video, including after the toolbar fades. The widget
tests also cover scrolling long menus in a small video and changing playback speed.

Generate the fixture in the authorized SSD folder and use the guarded harness:

```sh
python3 tool/create_player_fixture.py /Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv
python3 tool/benchmark_player.py \
  --fixture /Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv \
  --storage-root /Volumes/AppleExpanded/Library/PeerStream \
  --profile --output /tmp/peerstream-player-verification.json
```

Add `--cold` to the guarded harness to measure the bundled legal Big
Buck Bunny torrent through libtorrent and the loopback HTTP Range server. This
uses a fresh temporary payload directory, empty playback preferences and history,
and no provider or artwork requests. The test verifies the loaded bridge revision,
measures the video controller's first rendered frame and the screen's playing
transition, checks the ten-second target against the later timestamp,
and confirms the video is still partially downloaded at that frame. Network runs
depend on current peers and connectivity; report the measured result with that
scope. The generated local fixture has a separate five-second startup limit.

The app prepares its shared player and renderer while Home loads. The test does
the same before mounting the selected source, and reports that preparation time
separately as `playerWarmUpMs`. The test emits `[PlayerVerification]` JSON with
frame/visible-playback time, downloaded bytes, file completeness and the bridge
revision. It keeps the Flutter test lifecycle active when the macOS launcher
cannot bring the test window forward. It does not write to the user's playback
cache or history after the isolation fix described in the roadmap.
Temporary media remains in the sandbox's temporary directory for inspection.

The integration test builds a test entry point into the debug app bundle. Restore
the normal app afterwards:

```sh
flutter build macos --debug -t lib/main.dart
open -n build/macos/Build/Products/Debug/PeerStream.app
```

## 2026-10-14 continuation

That continuation used `bridge-1.9.9+lt2.1.1`. See the
[roadmap verification record](UX_PERFORMANCE_ROADMAP.md) for the latest profile
samples, explicit missed public-torrent target, data-isolation incident, long-soak
status and controlled matrix. Earlier timings above remain historical samples.
The native default player and loopback streaming route remain the defaults.

The updated fixture uses the actual native cache implementation behind an
isolated storage locator, or the service's remote cache adapter in an isolated
root. Its cache wrapper implements the interface rather than inheriting live
mutation methods. History and queue state are injected separately. Tests snapshot
and compare real saved metadata; they never automatically restore over newer data.
