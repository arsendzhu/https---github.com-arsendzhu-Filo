#!/usr/bin/env bash
# Project hook for scripts/verify.sh (verify.sh runs this when it is executable).
# verify.sh's own Godot step needs `timeout`, which is not installed on macOS by default, so
# the real gates live here: the Godot unit tests + offline end-to-end scenarios (scripts/test.sh)
# and the audio/segmenter tests (scripts/test_audio.sh, once present).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0

echo "-- Godot unit tests + offline end-to-end (scripts/test.sh)"
if ! "$ROOT/scripts/test.sh"; then FAIL=1; fi

if [ -x "$ROOT/scripts/test_audio.sh" ]; then
  echo "-- audio pipeline tests (scripts/test_audio.sh)"
  if ! "$ROOT/scripts/test_audio.sh"; then FAIL=1; fi
fi

exit "$FAIL"
