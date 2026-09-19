#!/bin/zsh
# Builds the tiny macOS GDExtension that lets Filo's window float above
# full-screen apps and games (app/native/libfilo_overlay.dylib).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/native"
mkdir -p "$OUT"
clang -dynamiclib -O2 -fobjc-arc -framework Cocoa -target arm64-apple-macos13.0 \
  -o "$OUT/libfilo_overlay.dylib" "$ROOT/native/filo_overlay.m"
codesign --force --sign - "$OUT/libfilo_overlay.dylib" >/dev/null 2>&1 || true
echo "Built: $OUT/libfilo_overlay.dylib"
source "$ROOT/scripts/find_godot.sh"
"$GODOT" --headless --path "$ROOT/app" --import >/dev/null 2>&1 || true
