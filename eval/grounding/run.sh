#!/bin/zsh
# Builds the grounding eval against the app's own sources and runs it.
# Usage: ./run.sh [--dump] [--zoom] [--only <case>] [--worker <url>]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../../leanring-buddy"
BUILD="$HERE/build"
mkdir -p "$BUILD"
SOURCES=(
  "$APP/Sounder/Backend/SounderModels.swift"
  "$APP/Sounder/Backend/ChatModelClient.swift"
  "$APP/Sounder/Backend/ClaudeChatClient.swift"
  "$APP/Sounder/Capture/NativeScreenCaptureUtility.swift"
  "$APP/Sounder/Grounding/ScreenElementDetector.swift"
  "$APP/Sounder/Grounding/SetOfMarkRenderer.swift"
  "$APP/Sounder/Router/GeneralModePipeline.swift"
  "$HERE/Stubs.swift"
  "$HERE/main.swift"
)
if [[ ! -x "$BUILD/grounding-eval" || -n "$(find "${SOURCES[@]}" -newer "$BUILD/grounding-eval" 2>/dev/null)" ]]; then
  echo "building…"
  xcrun swiftc -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature NonisolatedNonsendingByDefault -DDEBUG \
    -target arm64-apple-macos14.2 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -module-name grounding_eval "${SOURCES[@]}" -o "$BUILD/grounding-eval"
fi
exec "$BUILD/grounding-eval" --root "$HERE" "$@"
