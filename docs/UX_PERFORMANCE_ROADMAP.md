# PeerStream UX and performance implementation

Updated 2026-10-16. The native libtorrent engine and default media_kit player remain the production defaults. The Rust companion is an opt-in prototype using isolated storage. No real-cache ownership switch or background/login mode is enabled.

## Implemented behavior

- Startup uses real session phases, with cancel and another-source actions after ten seconds. Retry and source replacement preserve position; decoder callbacks from an older opening cannot consume a new resume request.
- Audio, subtitle, speed, size, ratio and timing controls stay inside the video. Subtitle/audio offsets use 100/50 ms increments and persist per media file. Track changes are verified against native mpv properties.
- Player menus contain keyboard focus, announce selection, and support Escape/outside-click dismissal. A floating mini-player reuses the existing window/player; it is not native Picture-in-Picture.
- Local source reliability observations include startup time and stalls, expire after seven days, and treat unknown sources neutrally. Addon failures and elapsed times are visible.
- Balanced/Low-memory bridge budgets are 128/64 MiB, with one speculative metadata preparation, thirty-second expiry, inactive-handle release and memory-pressure cleanup. These are component budgets, not total process limits.
- Storage distinguishes missing, unwritable and full drives. Failed reads expose Retry; failed writes preserve previous saved state. Interrupted migration uses an ownership journal. Large data never silently falls back to internal storage.
- The persistent queue can be reordered. Optional autoplay has a cancelable ten-second countdown and defaults off. The player also includes a sleep timer.
- Explicit offline saves support pause/resume/cancel, storage reservation, protected entries, selected-file verification and playback priority. Protected saves count against the budget; explicit cache clearing removes them too.
- Continue Watching supports restart, remove and mark watched. Library includes collections and watched filters; discovery retains search/filter preferences. A series with watched episodes is not marked entirely watched.

App data remains under `/Volumes/AppleExpanded/Library/PeerStream`. Native session logs rotate at 4 MiB under the selected session directory. See [storage behavior](STORAGE_DIRECTORY.md).

## Download and external-player extension

Source cards now have Download and External player actions. Downloads manages
torrent and finite HTTP video saves, offline playback and native Save file as…
export. macOS can launch installed VLC/IINA/mpv or a manually selected compatible
app while retaining the owned torrent stream. The extension passed 333 Flutter
tests and real download/offline/VLC checks; it does not change the failed Rust
adoption or distribution gates below. See [usage and evidence](DOWNLOADS_EXTERNAL_PLAYERS.md).

## Native startup fix

Bridge **`1.9.10+lt2.1.1`** replaces `stop_when_ready` during streaming preparation. That flag force-pauses a torrent, including metadata downloading, and can introduce reconnection delays. The bridge now uses an `upload_mode` guard to forbid piece requests while retaining metadata peers. It clears the guard after installing selected-piece priorities/deadlines or explicit offline file priorities. Deadline-based streaming remains in place; the full file is not required before playback.

Healthy resume snapshots omit this transient guard, preserving compatibility with older bridges. Real disk-error upload mode remains preserved. Native smoke tests check zero payload requests/bytes during a one-second metadata-only interval, and that saving state does not change the live guard.

An isolated native transport probe measured **11.92 s before / 1.14 s after** from metadata preparation to the first exact Range bytes, excluding the explicit one-second observation. These are single transport samples, not player p95. [Probe record](benchmarks/metadata-peer-probe-macos-2026-10-15.json).

The profile applier also avoids writing mpv's initial probe-size sentinel `0`, which mpv reports but rejects at runtime. Initial direct opens leave automatic probing untouched; restoration after a torrent uses the bundled libavformat default of 5,000,000 bytes. Native and unit checks guard against the invalid reset. [Runtime probe record](benchmarks/player-probe-reset-macos-2026-10-15.json).

## Measured results

The wire fixture uses generated original multi-track MKV video and an explicit loopback BitTorrent peer with a 1 MiB/s upload budget. It has no HTTP web seed; an inert loopback tracker URI prevents injection of production default public trackers. The seed disables DHT/LSD/UPnP/NAT-PMP and allows normal TCP/uTP transport. The app's network discovery settings remain unchanged.

| Current 1.9.10 test | Result | Scope |
|---|---|---|
| Native wire startup, 20 trials | Median **1.917 s**, p95 **2.912 s** | Fresh app/cache per trial; passed controlled target |
| Service wire startup, 20 trials | Median **2.419 s**, p95 **3.169 s** | Fresh app/helper/cache per trial; passed controlled target |
| Native torrent churn | 30 sessions, 60 position-confirmed seeks; footprint **+9.80%** | Passed this run's 10% growth threshold |
| Service torrent churn | 30 sessions, 60 position-confirmed seeks; combined footprint **+10.08%** | Functional cycles passed; growth threshold **failed** |
| Public legal cold observations | **11.031 s** and **6.435 s** | First missed ten seconds; no public-network p95 claim |
| Source-built native package | All eight default-player cases passed | Current host only; one sample/case |
| Normal controlled comparison | 137 completed trials; trial 138 stopped in the harness; separate fresh batch **24/24 passed** | Full 160-trial acceptance incomplete; batches not pooled |

Every wire trial started before selected-file completion. Startup uses the later of first rendered frame and playing state; app-lifetime renderer preparation is reported separately, matching the controller prepared while Home loads. Native downloaded-byte statistics can lag the first frame; a zero sampled counter does not mean video played without receiving bytes. [Complete wire measurements and hardware](benchmarks/local-peer-macos-2026-10-15.json).

Native churn warmed/settled footprint was **306,463,920 / 336,506,715 bytes**. Service combined app/helper footprint was **308,649,149 / 339,751,443 bytes**. The original seed buffer is shared and included in app footprint; response chunks use immutable views. Neither moving memory to a helper nor these measurements establishes a memory reduction. Earlier runs around the threshold are retained below. This is active process footprint, not a configured memory ceiling or proof against every leak.

The public samples started after **1,835,008 / 3,145,728 bytes** of a **276,134,947-byte** file, with no source-provider lookup. Peer availability, bandwidth and metadata latency still affect public sources. The ten-second recovery action remains necessary.

The normal comparison requested twenty randomized blocks covering local files, direct HTTP, cold/warm/partial native torrents, and cold/warm/partial service sessions. It completed 137 trials before a test harness failure: trial 138 rendered in 495 ms, then the local five-second pump timeout left a Flutter guarded pump unfinished and cleanup raised a conflict. The pending frame delay itself remains unexplained. The fixture now relies on the outer 180-second process watchdog, which terminates a stalled trial without trying to clean up an uncanceled pump. A separate three-block run on October 16 passed all **24 trials**, including three helper-crash/position-recovery checks, and checks the revised harness; results are not pooled to claim the original 160-trial acceptance passed. [Comparison records](benchmarks/controlled-matrix-macos-2026-10-16.json). Its original HTTP web seed shares a 1 MiB/s budget. Warm metadata endpoints return HTTP 503 throughout playback and helper recovery. Tests use the production native cache store and actual remote cache adapter in owned test roots. Cached seek timing confirms player position; it does not measure compositor-frame seek latency.

## Rust companion and lifecycle

`native/peerstream-service` contains a reusable core and executable. A dedicated native worker owns the existing C ABI and bounded command channel. Flutter sends commands and consumes coalesced SSE snapshots. Media bytes travel directly from the native loopback Range server to libmpv, outside Dart/Rust JSON IPC.

The authenticated v1 API covers health/capabilities, opaque sessions, metadata, playback hints, native verification, downloads, persistence, resource profiles and cache maintenance. Creation request IDs deduplicate retries. Instance identity rejects stale handles; root locking excludes duplicate writers. Browser Origin requests are rejected and stream URLs require random session capabilities. The private stdin bootstrap carries the token and acts as a parent-lifetime lease. Default shutdown stops the helper and confirms exit before releasing ownership.

Torrent-URL replay tries saved resume data and cached `.torrent` metadata before contacting the original URL. Only an explicit `422/cache_miss` permits fetching metadata and retrying creation; ambiguous timeouts and storage errors propagate. Capabilities negotiate this behavior with older helpers.

Terminal transport errors remain visible until explicit Retry. mpv log-stream diagnostics can recover when real playback progress resumes; buffering events alone cannot erase failures, and player diagnostics cannot downgrade a terminal transport error. Resume settlement, asynchronous seek callbacks and watchdogs are scoped to the current media opening.

The experiment uses `temp/service-prototype-v1`, **not the real replay cache**. Flutter remains the sole UI/player; no hidden second Flutter engine is created. To build the optional backend:

```sh
tool/service-cargo.sh build --release --locked
flutter build macos --debug --dart-define=PEERSTREAM_SERVICE_EXPERIMENTAL=true
```

## Checks and adoption gates

- Flutter: **318 tests passed, one skipped**; the disposable-full-volume case was separately executed successfully. Static analysis and normal macOS debug builds passed.
- Rust: formatting, Clippy with warnings denied and three ABI/identity tests passed. Five Dart adapter regressions cover cached replay, explicit miss, ambiguous failure, storage errors and older-helper compatibility.
- Packaged bridge 1.9.10: native metadata-only gating, healthy resume policy, authentication, duplicate ownership, Range head/tail/concurrent reads, reset and crash/restart checks passed.
- Ten storage/transport fault checks passed: corrupt-piece rejection/recovery, suffix/open-ended reads, cancellation, incomplete headers, real ENOSPC preserving previous index/resume state, release during full disk, disposable-volume removal/reconnection and exact recovery. The real SSD was never detached. [Fault results](benchmarks/native-faults-macos-2026-10-15.json).
- Four HTTPS checks passed, including rejecting an untrusted seed and accepting an explicitly trusted private CA. Framework-relative public trust is bundled; verification stays on. [TLS results](benchmarks/native-tls-macos-2026-10-15.json).
- Historical two-hour local playback passed **7,200 seconds / 470 native track changes / playing at the end** on bridge 1.9.8. It was not two hours of torrent traffic or a soak of the latest bridge. [Soak scope and measurements](benchmarks/two-hour-player-macos-2026-10-14.json).

**Service adoption remains disabled.** The latest service growth target failed. The incomplete comparison also measured a warm service/native median footprint ratio of **1.108**, exceeding the 1.10 budget; this is diagnostic evidence from the completed subset, not full acceptance. Comparative startup/memory/isolation summaries do not override that result or the following gates:

- Developer ID signing/notarization, macOS 12 hardware runtime and all-plugin portability remain unverified. Source-built bridge dependencies declare 12.0 and passed current-host playback; ordinary developer builds still use Homebrew libraries with newer minimum OS claims. [Packaging instructions](MACOS_NATIVE_PACKAGING.md).
- Signed app-launched sandboxed helper access/restart on the selected SSD passed earlier; independent SSD authorization after parent exit, persistent background mode, SMAppService registration and launch-at-login remain gated and unavailable.
- Visual seek-frame latency and a latest-bridge two-hour soak have not been established. Position acknowledgement and the historical soak have narrower scopes.
- One earlier Flutter Driver bootstrap stalled before the test body, with idle Flutter/Dart threads and no player work. Its cause remains unresolved; it is not counted as a playback sample or proof of a production startup defect.

No cloud backend, LAN service, transcoding, casting, browser torrent playback, torrent-engine rewrite, native PiP, automatic intro detection or thumbnail generation was added. Android service hosting is a later platform-specific phase. The browser release check remains blocked by existing native-player stub calls and the external MediaForge web int/BigInt incompatibility; external packages were not changed.

## Retained failures and data isolation

- A helper-crash test exposed late buffering erasing terminal errors; a regression failed before the fix. [Failed run](benchmarks/controlled-matrix-aborted-macos-2026-10-15.json).
- A later Retry lost position because an old media event cleared pending resume before open. Current opening guards fixed it; old results are excluded from current comparison. [Failed run](benchmarks/controlled-matrix-resume-failure-macos-2026-10-15.json).
- Previous native churn runs measured **10.86%** growth with copying response chunks and **10.03%** with views, both failed against the unchanged 10% threshold. Removing the test copy did not establish a production memory fix. [Copying seed](benchmarks/torrent-cycles-copying-seed-macos-2026-10-15.json), [view seed](benchmarks/torrent-cycles-view-seed-macos-2026-10-15.json).
- Before the native metadata fix, valid wire player samples missed ten seconds at **13.62 s native / 12.09 s service**. An initial private-torrent fixture was invalid for metadata exchange and is excluded. [Before-fix samples](benchmarks/local-peer-before-fix-macos-2026-10-15.json).

The first earlier soak mistakenly inherited the real history-removal method. Continue Watching is now empty; there is no pre-run snapshot and the user does not remember its previous contents, so loss or preservation cannot be established. No history was fabricated. The fixture now overrides save/remove/clear, isolates caches/journals/session state, and snapshots saved metadata with SHA-256, modification times and new-file checks. Subsequent guards report no changes; they cannot recover unknown earlier history. Guards never restore automatically over newer data.

The [October 16 machine-readable summary](benchmarks/roadmap-macos-2026-10-16.json) links the current results and remaining gates. Historical October 14 records retain their original scope.

## Repeat verification

Use the authorized SSD folder and run one timed suite at a time. Do not interact with the test window or attach accessibility inspection during measurements.

```sh
python3 tool/create_player_fixture.py /Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv
python3 tool/benchmark_local_peer.py \
  --fixture /Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv \
  --storage-root /Volumes/AppleExpanded/Library/PeerStream \
  --samples 20 --output /tmp/peerstream-local-peer.json
python3 tool/benchmark_matrix.py \
  --fixture /Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv \
  --storage-root /Volumes/AppleExpanded/Library/PeerStream \
  --samples 20 --output /tmp/peerstream-matrix.json
```

For churn, run `tool/benchmark_player.py` with the same fixture/storage arguments and `--profile --cycles 30 --torrent-cycles --resource-backend native` (then `service`). `--cold` adds a separate public-source observation. Native transport commands are documented in [the service README](../native/peerstream-service/README.md). Local `/tmp/peerstream-*` logs are execution artifacts; sanitized records under `docs/benchmarks` retain scope, failed gates and measurements.
