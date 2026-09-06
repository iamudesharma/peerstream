# PeerStream

PeerStream is a Flutter media discovery and peer-to-peer playback app. It uses TMDB for film and series metadata, queries configured Stremio-compatible source addons for exact matches, and plays native torrent sources through a private HTTP stream on `127.0.0.1`.

Use it only with content you are authorised to access and distribute.

## Features

- Browse movies, series, seasons, episodes, categories, and search results from TMDB.
- Query all enabled source addons concurrently and group results by provider.
- Support magnet links, `.torrent` files, and direct HTTPS media URLs.
- Resolve metadata, choose the intended streamable video file, and stream before the full file is downloaded.
- Provide live download, upload, peer, seed, buffer, and progress statistics.
- Select embedded audio and subtitle tracks.
- Change speed, volume, video fit, and aspect ratio; skip backward or forward ten seconds; use native fullscreen controls.
- Cache recent pieces and read ahead around playback for smoother seeking.

## Platform support

### macOS — verified

macOS is the actively verified native target. PeerStream builds the vendored libtorrent bridge from source and links it into `libtorrent_flutter.framework`. It has both client and server network entitlements for peer traffic and the local playback server.

Install development dependencies once:

```sh
brew install libtorrent-rasterbar boost openssl@3
```

Run the app:

```sh
flutter pub get
flutter run -d macos --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

### Android — native package support

The bundled native package supports Android API 24 and newer. Gradle downloads a matching native library for arm64-v8a, armeabi-v7a, and x86_64 when one is unavailable locally.

```sh
flutter run -d android --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

Test physical-device playback before release because peer connectivity and background behaviour vary by device and network.

### iOS — native package support

The package includes an iOS CocoaPods target. Build and sign through Xcode on macOS.

```sh
flutter run -d ios --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

Confirm device playback, background behaviour, and transport settings before release.

### Windows — native package support

The package contains a CMake target for Windows. Build with the Visual Studio C++ desktop toolchain, then package the matching native libtorrent dependencies with the release.

```sh
flutter run -d windows --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

### Linux — native package support

The package contains a Linux CMake target. Install the target distribution's libtorrent, OpenSSL, and C++ development packages before building.

```sh
flutter run -d linux --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

Test every distribution you plan to ship because runtime library package names differ.

### Web — discovery only

The web build supports browsing, metadata, and source discovery. Browser torrent playback is intentionally unavailable; the player reports that it is unsupported instead of attempting a native connection.

```sh
flutter run -d chrome --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

## Quick start

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN
```

Without a TMDB token, local demonstration metadata remains available. TMDB browsing, search, details, seasons, episodes, and addon lookup require a valid TMDB v4 read token. Pass it through `--dart-define`; never commit it.

## Source addons

Manage Stremio-compatible addon manifest URLs from the Sources screen settings. PeerStream queries each enabled addon in parallel using an exact IMDb movie ID or IMDb-season-episode ID. It preserves working alternatives if another provider fails or times out.

The supported stream forms are:

- Magnet URLs with an info hash, trackers, and an optional file index.
- Downloadable `.torrent` files.
- Direct HTTP(S) media URLs supplied by an addon.

Provider seed and peer values are hints supplied by the indexer, not proof that peers are actively delivering the first video pieces. PeerStream shows live session statistics and stops a source that cannot supply useful data for playback.

### Local source policy

An optional local policy can reject source IDs, provider names, torrent hosts, magnet trackers, and web seeds. Create `config/source_blocklist.json` from the example or reference a private file outside the repository:

```sh
flutter run -d macos \
  --dart-define=TMDB_READ_TOKEN=YOUR_TMDB_V4_READ_TOKEN \
  --dart-define=SOURCE_BLOCKLIST_PATH=/absolute/path/source_blocklist.json
```

The policy runs while listing sources and immediately before native playback. When no file is supplied, the app uses an empty local policy.

## Playback architecture

1. The selected magnet or `.torrent` enters one foreground libtorrent session.
2. Torrent metadata exposes available files. The provider file index is used when present; otherwise the app selects the largest non-sample video file.
3. The native bridge creates a private HTTP range server on `127.0.0.1`.
4. `media_kit` and libmpv request the byte ranges required to play.
5. Libtorrent prioritises pieces around the player read position. Seeking sends new range requests and reprioritises the required pieces.
6. Leaving the player stops the session and clears its temporary data.

## Player controls

The player overlay provides play/pause, scrubber, and native fullscreen. The control card below the video also provides:

- Ten-second rewind and forward buttons.
- Playback speeds from 0.5× to 2×.
- Volume control from mute through 100%.
- Fit, fill-screen, and stretch sizing.
- Original, 4:3, 16:9, and 21:9 viewport ratios.
- Embedded audio track selection.
- Embedded subtitle selection, including **Off**.

Audio and subtitle choices appear after the selected file has exposed its media tracks. A file with only one audio stream or no subtitle stream presents only the tracks it has.

## Streaming cache

The native engine is configured for responsive streaming with a 256 MB session cache, 384 MB stream cache ceiling, 85% read-ahead, 8 MB startup preload, up to 32 active stream connections, and a 120-second reader-less transfer timeout. The engine still prioritises the player's current byte range over cache filling.

## Project layout

```text
lib/
  features/             Browse, source-selection, and player UI
  models/               Media, sources, streaming state, and statistics
  providers/            Riverpod state and route integration
  services/streaming/   Foreground playback and stalled-source handling
  services/torrent/     Addons, policy, engine adapter, and bundled demos
packages/libtorrent_flutter/
                        Vendored FFI package and native bridge source
macos/                  Runner, entitlements, and CocoaPods integration
test/                   Unit and widget tests
```

## Build and test

```sh
flutter analyze
flutter test
flutter build macos --debug
flutter build macos --release
```

## Troubleshooting

### Missing `liblibtorrent_flutter.dylib`

Close any old PeerStream process and rebuild. The source build now loads `libtorrent_flutter.framework` from the application bundle rather than the legacy standalone dylib.

```sh
flutter clean
flutter pub get
flutter build macos --debug
```

### Video does not start

Provider counts are not live transfer measurements. Give the session time to connect and request initial pieces, then select another authorised source if it cannot deliver data. On macOS, the native bridge writes a focused trace to `/tmp/torrent_bridge.log` while playback is active.

### macOS native build fails

```sh
brew install libtorrent-rasterbar boost openssl@3
flutter clean
flutter pub get
flutter build macos --debug
```

## Notices

The bundled demonstration catalogue includes Big Buck Bunny, Sintel, and Tears of Steel. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [docs/WEBTORRENT_FUTURE.md](docs/WEBTORRENT_FUTURE.md) for source and WebTorrent notes.
