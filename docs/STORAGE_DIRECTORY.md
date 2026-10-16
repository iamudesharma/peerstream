# App storage folder

In **Settings → Playback & Storage → Storage folder**, select a writable folder
on the external drive. Folder changes apply on the next app launch. PeerStream
copies saved app data before committing the new location, then removes its own
old files. Choose a separate folder without existing `data`, `cache` or `temp`
contents; unrelated files are never removed.

The selected folder contains:

- `data`: cached torrent video and resume files, subtitles, watch history,
  saved titles, provider configuration, playback preferences and app settings.
- `cache`: resized artwork, its index and torrent session state.
- `temp`: app temporary storage.

macOS uses a user-selected read/write folder and an app-scoped security bookmark.
The small locator/bookmark and macOS sandbox metadata remain internal. Native
session logs use the selected session directory; operating-system crash reports
remain managed by macOS. An unavailable drive prevents new file writes rather than
silently creating another cache on the internal disk. A failed copy keeps the
original data and reports the problem in Storage settings.

**Clear all cached data** removes video, artwork and app subtitle copies while
preserving history, saved titles, providers, settings and cache/language limits.
Native torrent handles are released before deleting their files.
Clearing waits for background source preparation, blocks new playback until
deletion finishes and shares repeated clear requests. Selecting the active
folder cancels a pending move to another folder.

## Recovery hardening verified on 2026-10-14

The active folder remains `/Volumes/AppleExpanded/Library/PeerStream`.
Failed history, saved-list and cache-index reads now surface errors rather than
becoming empty data. Preference/list writes are serialized, and failed writes
leave their displayed saved state unchanged. Continue Watching and preferences
have read-only Retry actions. A native audio/subtitle change can succeed even if
saving its language preference fails; the feedback distinguishes those outcomes.

Migration writes an atomic ownership journal and marks copied directories. If a
process stops before location activation, the next attempt rolls back only its
owned copies and retries from the original source. It refuses unknown files,
symlinks or unowned directories. Tests cover commit failures and interrupted
installation journals. A crash after locator activation but before cleanup can
leave old copies behind; they are not deleted by guessing at another folder's
ownership. This is not a physical power-loss durability guarantee.

Sixteen isolated storage tests passed, including a real full filesystem on a
private 64 MiB HFS+ disk image. Native service fault tests also detach and reattach
their own image, reject corrupt pieces, recover exact bytes, preserve old cache
and resume records on ENOSPC, and stop sessions despite persistence failure.
The actual user SSD was not unmounted. Temporary images were detached and removed.
See [fault results](benchmarks/native-faults-macos-2026-10-14.json).

Subsequent guarded tests changed no saved metadata contents or modification
times. This does not resolve the earlier Continue Watching test-isolation
incident: its pre-run contents remain unknown. See
[the incident record](UX_PERFORMANCE_ROADMAP.md#data-isolation-incident).

## Earlier verification on 2026-10-13

Verified on macOS on 2026-10-13: cleared approximately 4.3 GB of old video cache;
selected `/Volumes/AppleExpanded/Library/PeerStream` in the native folder picker;
restored its security scope and activated the folder across app restarts;
observed new artwork files and their index on the SSD with the old internal
cache directories empty; played the bundled legal Big Buck Bunny source and
observed approximately 40 MB of torrent payload on the SSD. Verification video
cache was removed afterwards, and the original watch-history file was restored
byte-for-byte. The default player retains localhost HTTP Range streaming. The
source-built bridge remains `bridge-1.9.7+lt2.0.11`.

278 Dart/widget tests passed, analyzer clean, macOS debug build passed. Storage
tests cover payload and resume-file moves, cached-path rebasing, artwork cache
round trips and clearing, preserved preferences, failed copies/commits,
destination collisions, disconnected drives and concurrent shutdown. Drive
disconnection is simulated in filesystem tests; the working SSD was not
unmounted during validation. Other platforms have not been verified on hardware.

The native cache-reset integration check streamed two HTTP Range responses from
the same bundled legal torrent, with an engine reset and deletion of its isolated
SSD cache between them. Both returned 206 and the requested 1,024 bytes. Its
temporary files were removed; user cache and watch history were not used. Run it
after selecting the SSD folder, then restore the normal application entry point:

```sh
flutter test -d macos integration_test/storage_reset_test.dart
flutter build macos --debug -t lib/main.dart
```
