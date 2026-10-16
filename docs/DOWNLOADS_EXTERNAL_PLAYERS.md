# Video downloads and external players

Implemented and verified on macOS, October 16, 2026. The normal native engine and
media_kit player remain the defaults; the experimental Rust backend stays off.

## Download a video

Choose **Download** on a source card. The **Downloads** screen opens immediately
while preparation continues, so Pause and Cancel remain reachable during metadata
exchange. Downloads is also available from Settings and the navigation rail (or
the app-bar button on smaller windows).

- Torrent saves download the selected video file and require native piece
  verification before declaring it available offline.
- Direct HTTP/HTTPS video files stream to the selected storage drive. A temporary
  `.download` file becomes a completed file only after a successful response,
  matching declared length when supplied, nonempty EOF and flushed disk writes.
  This validates transfer completeness, not an unknown publisher's content hash.
- Pause retains partial data. HTTP resume requires a server validator and exact
  Content-Range; a server ignoring Range restarts the file safely. Missing or
  invalid validator metadata also restarts rather than appending incompatible
  bytes. Header and episode variants use different cache identities.
- Completed saves are protected from automatic cache eviction and count against
  the storage budget. Cancel stops work and removes protection, preserving
  reusable partial data. Explicit cache clearing also removes protected saves.
- Transfers pause during playback and stop on app quit. The default player's
  **Download video** setting queues the save until playback stops.
- Completed entries offer **Play downloaded video**, **Open in external player…**
  and **Save file as…**. Export rechecks the saved file, asks for a destination in
  a native Save dialog, then copies on a background worker and atomically
  activates the result. Cancel leaves the original alone. Exported copies are
  independent of cache clearing and use additional disk space.

These downloads support finite video files and selected torrent files. HLS/DASH
playlist downloads and DRM acquisition are not implemented. An unavailable SSD,
full disk, broken response or unsupported source produces an error; large data
never silently moves to internal storage. Direct download headers are used for
the selected request and are never included in application arguments.

## Open another player

Choose **External player** on a source card, or use a completed download's action
menu. The chooser detects installed VLC, IINA and mpv bundle registrations and
also offers **Choose application…**. Select an installed app that supports the
video's container and codecs. PeerStream does not install a player or change the
system's default file associations.

The native bridge uses Apple's
[NSWorkspace open API](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))
with separate URL and application arguments, without shell command construction.
A torrent is prepared with the existing native engine and handed over as its
capability-protected loopback Range URL. A completed save uses its local file.
Direct streams pass their URL, or use a per-session loopback relay when addon
headers are required. That relay forwards GET/HEAD and Range responses with
backpressure, rejects browser Origin requests, and never proxies arbitrary URLs.
Header-dependent adaptive playlists cannot use this simple file relay.

Keep PeerStream's external-playback screen open for streamed sources. Back or
**Stop streaming** releases the owned stream and relay; it cannot terminate an
external player's buffered playback or independently opened local file. Closing
an older screen cannot stop a newer playback session. The app also stops its
streams on quit. Player-specific startup watchdogs stop after OS delivery is
acknowledged; delivery is never recorded as a decoded first frame. Audio,
subtitles, seeking and watch position belong to the external player. PeerStream
does not fabricate Continue Watching positions for external playback.

Saved-source launches and direct download retries respect the source blocklist.
External launching/export is currently a macOS feature; the browser remains
discovery-only. Other installed compatible apps can be chosen, but this host's
executed external-player verification used VLC 3.0.17.3, not every player/codec.

## Executed verification

The generated original 60-second multi-track MKV is 4,863,960 bytes with SHA-256
`78a2b2e129b789ea5c2822882bf781621c10efa8d8d8e84adfe92d0337eab650`.

- Native integration downloaded it through libtorrent and direct HTTP into
  isolated SSD roots. Both completed files matched the original SHA-256.
- The source server was then closed. The real default player rendered the
  downloaded file from cache. This is a functional check, not a startup p95.
- Native UI QA exercised the source Download action, direct Pause/Resume,
  completed entries, the Save dialog and the custom application picker.
- The exported SSD copy matched the same original size and SHA-256.
- VLC displayed advancing video from a torrent stream and a downloaded file;
  its seek control moved the torrent fixture to 00:30. OS delivery alone was not
  used as evidence that decoding worked.
- Transport tests cover source headers, correct resume, a server ignoring Range,
  invalid ranges, storage-budget refusal, cancellation and playlist rejection.
  Relay/coordinator tests cover HEAD/Range, loopback capabilities, browser-origin
  refusal, cancellation, launch failure and stale-session ownership. Widget tests
  cover complete-file export, missing-file refusal and blocked-source rejection.
- Saved app metadata was snapshotted before testing and unchanged afterwards.
  QA did not insert fixture videos into the user's cache or Continue Watching.

Run the native check with the authorized SSD mounted:

```sh
caffeinate -d -i -m flutter test -d macos \
  integration_test/video_actions_test.dart \
  --dart-define=PEERSTREAM_PLAYER_FIXTURE=/Volumes/AppleExpanded/Library/PeerStream/temp/player-fixture.mkv
```

The test uses the existing generated fixture helper, an isolated cache/session
root and an in-memory experience journal. Native tests and UI QA must run
separately. Do not attach accessibility inspection to the Flutter integration
test window. A first fixture run stopped after both downloads because it queried
an already-closed server's port; retained sources fixed the fixture and the full
native check passed on subsequent runs.
