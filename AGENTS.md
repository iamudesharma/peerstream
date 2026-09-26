# AGENTS.md

PeerStream is a DartNative media-discovery and peer-to-peer playback app: TMDB
metadata, Stremio-compatible source addons, and native libtorrent playback
through a loopback HTTP range server. Shipping targets are **iOS and Android**.
macOS and web are not DartNative platforms. Playback uses
`dartnative_video_player` (AVPlayer on iOS, ExoPlayer on Android).

Own builds need a dartpub.dev license. Set it with
`dn config --license-key dnk_…` or `DN_LICENSE_KEY`. Do not commit the key.
Demos run without one; this app does not.

## Setup

- Install the CLI: `curl -fsSL https://cdn.dartnative.com/install.sh | sh`
  (installs to `~/zero`). Android builds need SDK 36. iOS builds need macOS
  and Xcode 26.3+.
- Resolve packages with `dn pub get` only. Cursor/VS Code pub-get-on-save is
  off (`.vscode/settings.json`: `dart.runPubGetOnPubspecChanges: never`).
  Commit `pubspec.lock` and `dn_plugins.lock`.
- `packages/libtorrent_flutter` is a pure Dart FFI package (GPL-3.0). It is
  not a Flutter plugin. Android loads `liblibtorrent_flutter.so` with
  `DynamicLibrary.open`. Fetch the prebuilt libraries before an Android
  build: `sh tool/fetch_libtorrent_android.sh` (also hooked to Gradle
  `preBuild`). On a Mac, `sh tool/fetch_libtorrent_ios.sh` downloads the
  xcframework that Runner force-loads so `DynamicLibrary.process()` can see
  the C ABI.
- `nativeBridgeVersion` in `lib/services/torrent/native_torrent_engine.dart`
  must match `kBridgeVersion` in
  `packages/libtorrent_flutter/src/torrent_bridge.cpp`; bump both together.
- Loopback playback is cleartext HTTP. Android sets
  `android:usesCleartextTraffic` and iOS allows local networking
  (`NSAllowsLocalNetworking`).

## Commands

```sh
dn pub get
dn analyze
dn test
dn test test/playback_session_test.dart
dn run -d android
```

- App config is `--dart-define` only; never commit tokens. `TMDB_READ_TOKEN`
  is optional (Cinemeta + Streaming Catalogs work keyless); also
  `STREAMING_CATALOGS_ENABLED`, `STREAMING_CATALOGS_MANIFEST_URL`,
  `CINEMETA_BASE_URL`, `SOURCE_BLOCKLIST_PATH`. Pass the license as
  `DN_LICENSE_KEY` in the environment, not as a dart-define that gets
  committed.

## Architecture

- `lib/features/` screens, `lib/providers/app_store.dart` is the single
  `AppStore` (`ChangeNotifier` / `Loadable` where the tree changes, `signal`
  for the shell tab). `lib/services/` domain logic, `lib/models/`, `lib/core/`
  shared config and widgets.
- Navigation is `registerRoutes` plus `Navigator.push` / `pushNamed`.
  `lib/core/navigation.dart` keeps the old path strings. Argument screens
  (details, sources, player) use `PageRoute(settings: '/name', builder:)` so
  hot restart can restore the stack. The player receives the torrent source
  object in the builder.
- `DartNativePluginRegistrant.registerAll()` is the first line of `main`.
  The root passed to `runApp` is `PeerStreamApp`. Do not use `App(home:)`.
- Platform store variants use conditional exports. Change every variant when
  an interface changes. Path and preference plugins are
  `dartnative_path_provider` (synchronous `String` paths) and
  `dartnative_shared_preferences`.
- Playback: source resolution → `StreamingService` → `NativeTorrentEngine`
  (`dart:ffi`) → libtorrent loopback HTTP server → `VideoPlayerController`
  with `VideoDataSource.network` and caching off. AVPlayer and ExoPlayer do
  not match libmpv. Files they reject fail through the existing error path.
  `lib/services/streaming/playback_config.dart` owns coordinated timeout and
  cache budgets.
- `nativeBridgeVersion` must stay matched to `kBridgeVersion`.

## Constraints

- Sources stay legal/reviewed: bundled WebTorrent demo catalog plus
  user-managed Stremio addons only — no scraping. Update
  `THIRD_PARTY_NOTICES.md` when bundled content changes.
- `config/source_blocklist.json` is private (gitignored); schema in
  `config/source_blocklist.example.json`.
- Do not register libtorrent as a method-channel plugin.
- Local workflow notes are in `.commandcode/taste/` (gitignored).
