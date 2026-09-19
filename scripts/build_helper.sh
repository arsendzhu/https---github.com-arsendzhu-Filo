#!/bin/zsh
# Builds the native macOS helper (global hotkey + speech) into an .app bundle
# so macOS attributes microphone / speech permissions to "Filo Helper".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/helper/build/Filo Helper.app"
BIN="$APP/Contents/MacOS/filo-helper"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install Xcode or the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/helper/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

echo "Compiling helper..."
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$BIN" "$ROOT"/helper/Sources/*.swift \
  -framework Cocoa -framework Carbon -framework Speech -framework AVFoundation

# Ad-hoc signature: gives the bundle a stable identity for the permission prompts.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (continuing unsigned)"
echo "Built: $APP"
