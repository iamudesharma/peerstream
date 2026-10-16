#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC=/usr/bin/clang
export CXX=/usr/bin/clang++
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=/usr/bin/clang
cd "$ROOT/native/peerstream-service"
exec cargo "$@"
