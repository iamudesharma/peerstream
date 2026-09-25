#!/bin/sh
# Downloads the prebuilt Android libtorrent bridge into the DartNative app
# jniLibs directory. DynamicLibrary.open('liblibtorrent_flutter.so') loads it
# from the APK; this is not a Flutter plugin.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^version:[[:space:]]*//p' "$ROOT/packages/libtorrent_flutter/pubspec.yaml" | head -n 1)
BASE="https://github.com/ayman708-UX/libtorrent_flutter/releases/download/v${VERSION}"
JNI="$ROOT/android/app/src/main/jniLibs"

for abi in arm64-v8a armeabi-v7a x86_64; do
  dest="$JNI/$abi/liblibtorrent_flutter.so"
  if [ -f "$dest" ]; then
    continue
  fi
  mkdir -p "$JNI/$abi"
  tmp=$(mktemp -d)
  echo "libtorrent_flutter: downloading $abi"
  curl -fsSL "$BASE/android-native-lib-${abi}.zip" -o "$tmp/lib.zip"
  unzip -o -q "$tmp/lib.zip" -d "$tmp/out"
  found=$(find "$tmp/out" -name 'liblibtorrent_flutter.so' | head -n 1)
  if [ -z "$found" ]; then
    echo "libtorrent_flutter: $abi archive did not contain liblibtorrent_flutter.so" >&2
    rm -rf "$tmp"
    exit 1
  fi
  cp "$found" "$dest"
  rm -rf "$tmp"
done
