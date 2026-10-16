#!/bin/sh
# Run after Flutter build. Does not register a login item or enable the experiment.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP=${1:?Usage: tool/package-service.sh /absolute/path/PeerStream.app}
"$ROOT/tool/service-cargo.sh" build --release --locked
python3 "$ROOT/tool/bundle_native_dependencies.py" "$APP" --identity "${PEERSTREAM_SIGN_IDENTITY:--}"
mkdir -p "$APP/Contents/Helpers"
cp "$ROOT/native/peerstream-service/target/release/peerstream-service" "$APP/Contents/Helpers/peerstream-service"
codesign --force --sign "${PEERSTREAM_SIGN_IDENTITY:--}" --entitlements "$ROOT/macos/Runner/ServiceHelper.entitlements" "$APP/Contents/Helpers/peerstream-service"
# Re-sign the assembled development bundle, preserving existing app entitlements.
codesign --force --sign "${PEERSTREAM_SIGN_IDENTITY:--}" --entitlements "$ROOT/macos/Runner/DebugProfile.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
