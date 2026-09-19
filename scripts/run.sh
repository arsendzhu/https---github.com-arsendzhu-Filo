#!/bin/zsh
# Runs Filo (Phase 0 demo). Extra arguments are passed to the app, e.g.:
#   scripts/run.sh                       normal demo
#   scripts/run.sh --showcase            tour of every animation state
#   scripts/run.sh --ask "how do I beat the chained ogre" --mute
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/load_env.sh"
source "$ROOT/scripts/find_godot.sh"
if [[ ! -d "$ROOT/app/.godot" ]]; then
  echo "First run: importing project..."
  "$GODOT" --headless --path "$ROOT/app" --import >/dev/null 2>&1 || true
fi
if [[ ! -f "$ROOT/app/native/libfilo_overlay.dylib" ]]; then
  "$ROOT/scripts/build_native.sh"
fi
if [[ ! -d "$ROOT/helper/build/Filo Helper.app" && "$*" != *"--no-helper"* && "$*" != *"--showcase"* ]]; then
  "$ROOT/scripts/build_helper.sh"
fi
exec "$GODOT" --path "$ROOT/app" -- "$@"
