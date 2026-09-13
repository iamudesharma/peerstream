# AGENTS.md

PeerStream is a Flutter media-discovery and peer-to-peer playback app: TMDB metadata,
Stremio-compatible source addons, and native libtorrent playback through a loopback
HTTP range server. macOS is the only actively verified target. Web is discovery-only
by design — playback reports unsupported (see `docs/WEBTORRENT_FUTURE.md`); don't
implement browser torrent playback.

## Setup gotchas

- `pubspec.yaml` / `pubspec_overrides.yaml` depend on packages outside this repo:
  `/Volumes/AppleExpanded/Code/Gym app/rust_image/packages/{media_forge,media_forge_player,pixel_surface}`.
  `flutter pub get` fails unless that volume is mounted.
- macOS compiles the native bridge from source through CocoaPods
  (`packages/libtorrent_flutter/macos/Classes/torrent_bridge_macos.cpp` includes
  `src/torrent_bridge.cpp`) and links Homebrew libraries. Install once:
  `brew install libtorrent-rasterbar boost openssl@3`. The podspec hardcodes
  `/opt/homebrew` and `/usr/local` search paths. `packages/libtorrent_flutter` is
  vendored upstream code (GPL-3.0) — fix it in place.
- `nativeBridgeVersion` in `lib/services/torrent/native_torrent_engine.dart` must match
  `kBridgeVersion` in `packages/libtorrent_flutter/src/torrent_bridge.cpp`; bump both
  together.

## Commands

```sh
flutter pub get
flutter analyze
flutter test                                  # pure Dart/widget tests, no native libs
flutter test test/playback_session_test.dart  # single file
flutter run -d macos --dart-define=TMDB_READ_TOKEN=...
flutter build macos --debug                   # native build verification
```

- No CI. Run `flutter analyze` and `flutter test` yourself before finishing.
- App config is `--dart-define` only; never commit tokens. `TMDB_READ_TOKEN` is optional
  (Cinemeta + Streaming Catalogs work keyless); also `STREAMING_CATALOGS_ENABLED`,
  `STREAMING_CATALOGS_MANIFEST_URL`, `CINEMETA_BASE_URL`, `SOURCE_BLOCKLIST_PATH`.
- After native/bundle changes, the fix is usually
  `flutter clean && flutter pub get && flutter build macos --debug`.

## Architecture

- `lib/features/` screens and go_router routes (`lib/app.dart`), `lib/providers/`
  Riverpod wiring (`app_providers.dart`), `lib/services/` domain logic, `lib/models/`,
  `lib/core/` shared config/widgets.
- Platform variants use conditional exports, e.g.
  `export 'x_web.dart' if (dart.library.io) 'x_native.dart';`, with `_io`/`_memory`
  store variants. Change every variant when an interface changes.
- Playback: source resolution → `StreamingService` → `NativeTorrentEngine` (FFI) →
  libtorrent loopback HTTP server → player. `lib/services/streaming/playback_config.dart`
  owns coordinated timeout/cache budgets — keep player and native waits in sync.
- Two player backends: default `media_kit` and experimental MediaForge
  (`useMediaForgePlayer` setting, default off, frozen per session in
  `lib/features/player/player_backend.dart`). MediaForge is the external path dep above.
- macOS playback diagnostics: native bridge log at `$TMPDIR/torrent_bridge.log`
  (sandboxed builds: `~/Library/Containers/dev.peerstream.peerstream/Data/tmp/torrent_bridge.log`).
  Stalled sources are expected to fail with explicit user-facing messages, not endless spinners.

## Constraints

- Sources stay legal/reviewed: bundled WebTorrent demo catalog plus user-managed Stremio
  addons only — no scraping. Update `THIRD_PARTY_NOTICES.md` when bundled content changes.
- `config/source_blocklist.json` is private (gitignored); schema in
  `config/source_blocklist.example.json`.
- Keep both `com.apple.security.network.client` and `com.apple.security.network.server`
  in the macOS entitlements; peer traffic and the loopback player server need them.
- Local workflow notes (plan-first, evidence/log-based diagnosis, macOS verification) are
  in `.commandcode/taste/` (gitignored).
