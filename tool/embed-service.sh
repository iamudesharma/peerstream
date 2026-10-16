#!/bin/sh
# Xcode phase: bundle the locally source-built service if it has been built.
set -eu
ROOT="$PROJECT_DIR/.."
BINARY="$ROOT/native/peerstream-service/target/release/peerstream-service"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
if [ -f "$BINARY" ]; then
  mkdir -p "$DEST"
  cp "$BINARY" "$DEST/peerstream-service"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --entitlements "$ROOT/macos/Runner/ServiceHelper.entitlements" "$DEST/peerstream-service"
fi

# The bridge must not require Homebrew on the playback machine.
python3 "$ROOT/tool/bundle_native_dependencies.py" "$TARGET_BUILD_DIR/$WRAPPER_NAME" --identity "${EXPANDED_CODE_SIGN_IDENTITY:--}"
