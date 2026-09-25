#!/bin/sh
# Downloads the prebuilt iOS xcframework. The DartNative Podfile does not
# install this package. Runner links the static archive with -force_load so
# DynamicLibrary.process() can resolve the C ABI. Run this on a Mac before
# the first iOS build.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$ROOT/packages/libtorrent_flutter/pubspec.yaml" | head -n 1)
BASE="https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v${VERSION}"
DEST="$ROOT/packages/libtorrent_flutter/ios/libtorrent_flutter.xcframework"
if [ -d "$DEST/ios-arm64" ]; then
  exit 0
fi
tmp=$(mktemp -d)
echo "libtorrent_flutter: downloading iOS xcframework"
curl -fsSL "$BASE/ios-native-lib.zip" -o "$tmp/ios.zip"
rm -rf "$DEST"
mkdir -p "$DEST"
unzip -o -q "$tmp/ios.zip" -d "$DEST"
rm -rf "$tmp"
if [ ! -f "$DEST/ios-arm64/liblibtorrent_flutter.a" ]; then
  echo "libtorrent_flutter: xcframework slice ios-arm64 is missing" >&2
  exit 1
fi
