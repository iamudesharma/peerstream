# Third-party notices

PeerStream uses the following major third-party projects. The dependency lockfile
contains the complete package list.

- **TMDB API** supplies metadata and images. This product uses the TMDB API but
  is not endorsed or certified by TMDB. TMDB data is used under its API terms.
- **libtorrent_flutter** is licensed under GPL-3.0 and wraps libtorrent. Its
  source and license are available at https://pub.dev/packages/libtorrent_flutter.
- **media_kit** is licensed under MIT and includes platform media libraries with
  their own notices.
- **Riverpod**, **Dio**, **go_router**, and **cached_network_image** retain their
  respective upstream licenses.

The demo films are not bundled. Their torrent descriptors come from
https://webtorrent.io/free-torrents and point to Blender Foundation open movies
published under Creative Commons Attribution 3.0. Verify upstream attribution
files when redistributing downloaded media.

## Bundled native bridge dependencies

macOS packaging copies the bridge's native dependencies into the app bundle:
libtorrent-rasterbar (BSD-style license), Boost.System (Boost Software License
1.0), and OpenSSL (Apache License 2.0). Their license texts are included under
`Contents/Resources/NativeLicenses` and in `licenses/native` in this repository.
The modified GPL-3.0 `libtorrent_flutter` bridge source remains under
`packages/libtorrent_flutter`; its license is also included in the bundle.

The optional Rust service dependencies are pinned in
`native/peerstream-service/Cargo.lock` and retain their upstream licenses.
Developer ID signing, notarization and distribution/source-offer review remain
separate release gates; a local ad-hoc signature is not a distribution approval.

The bundled native TLS trust file is Mozilla's public CA certificate data,
converted to PEM by curl (2026-09-25 extract), licensed under MPL 2.0.
The unmodified source is `resources/native-trust/cacert.pem`; the license is
`licenses/native/Mozilla-MPL-2.0.txt`. Source and update information:
https://curl.se/docs/caextract.html . Both the PEM and its license are included
in the macOS app resources.

The libtorrent build also incorporates upstream dependency code. Corresponding
notices for try_signal, ed25519, libdatachannel, usrsctp, libjuice, libsrtp, plog
and nlohmann/json are preserved in `licenses/native` and copied into the app.
The notices and source versions come from the verified libtorrent 2.1.1 release
archive, listed in `tool/build_portable_native.py`. This includes upstream's
`COPYING` attribution. Native WebRTC support is retained as part of that build;
PeerStream still does not implement browser torrent playback.
