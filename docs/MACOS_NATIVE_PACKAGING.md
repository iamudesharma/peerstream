# macOS native packaging

PeerStream's Xcode bundle phase copies the source-built Rust helper when present
and bundles the torrent framework's non-system dynamic libraries. It rewrites
references in the app copy, signs each library/framework and includes native
licenses and the pinned public CA file. It never edits Homebrew installations.
The helper uses inherited sandbox permissions and stops when its parent pipe
closes. This does not register background work or launch at login.

## Development package audit

After a normal macOS build:

```sh
python3 tool/audit_macos_package.py \
  build/macos/Build/Products/Debug/PeerStream.app \
  --output /tmp/peerstream-package-audit.json
```

The audit checks the torrent bridge/helper dependency graph, signatures, helper
sandbox inheritance, minimum OS declarations and exact bundled CA bytes. Its
scope does not include all Flutter/plugin dependencies. A valid ad-hoc signature
is not Developer ID signing or notarization. `distributionReady` remains false.

The development Homebrew libraries on the verification machine declare minimum
macOS versions 15 (Boost), 26 (libtorrent), and 27 (OpenSSL), despite the app's
macOS 12 target. Copying these files cannot establish macOS 12 compatibility.
Do not rewrite their minimum-version load commands to hide this problem.

## Isolated source build for macOS 12

`tool/build_portable_native.py` builds the same libtorrent 2.1.1 and OpenSSL 3.6.4
releases against Boost 1.88 headers into an explicit workspace. Downloads are
pinned to SHA-256 values from official release assets. It uses two compiler jobs
by default, retains ABI version 2 and native WebRTC support, and does not install
anything globally. Boost.System's upstream compatibility stub is built from
source; modern Boost.System implementation is in its headers.

```sh
python3 tool/build_portable_native.py \
  --workspace /Volumes/AppleExpanded/Code/steamio_clone/.tmp/portable-native \
  --jobs 2
```

The manifest is written only after all four dylibs actually declare macOS 12.
It records versions, architecture, source hashes and binary hashes. This is a
host-architecture build, not a universal binary. Interrupted compilation can be
resumed by rerunning the same command.

To test the resulting libraries, copy a built app into a disposable directory,
then bundle the verified prefix explicitly:

```sh
python3 tool/bundle_native_dependencies.py /absolute/path/PeerStream.app \
  --native-prefix /Volumes/AppleExpanded/Code/steamio_clone/.tmp/portable-native/prefix
```

Re-sign the assembled app with its app entitlements, audit it, then run native
Range/fault/TLS checks and the real default-player matrix against that package.
The prefix is not automatically selected by normal Flutter builds. Do not adopt
it solely because its minimum OS declarations pass. Oldest-supported-OS runtime
checks, packaging all other plugins, Developer ID signing/notarization and
independent background SSD authorization remain separate gates.

## Native HTTPS trust

The bridge resolves `Resources/NativeTrust/cacert.pem` from its framework location
before creating libtorrent. It validates the file with OpenSSL and configures it
only when `SSL_CERT_FILE` was not supplied. Certificate verification stays on.
The repository contains the official unmodified 2026-09-25 Mozilla CA extract,
whose SHA-256 was checked against curl's published checksum. Source, license and
update instructions are in `resources/native-trust/README.md`.

Run the isolated positive/negative TLS checks:

```sh
python3 tool/service_tls_smoke.py \
  --binary native/peerstream-service/target/release/peerstream-service \
  --library /absolute/path/PeerStream.app/Contents/Frameworks/libtorrent_flutter.framework/libtorrent_flutter \
  --temp-parent /Volumes/AppleExpanded/Library/PeerStream/temp \
  --output /tmp/peerstream-tls.json
```

This generates a private server and temporary CA files. It changes no Keychain
trust settings, rejects untrusted HTTPS seeds, and permits a verified download
only when that server's CA is explicitly supplied to the child process.
