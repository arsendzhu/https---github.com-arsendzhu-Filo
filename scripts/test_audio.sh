#!/bin/zsh
# Audio-capture tests that need no microphone and no permissions:
#   1. the whole helper compiles (swiftc to a temp dir - the installed Filo Helper.app is not touched)
#   2. the segmenter / pre-roll / tap-core / endpointing / debug-dump self-tests on synthetic signals
# The speech-fixture tests (test_vad_preroll_and_hangover, test_speech_not_clipped, keyword recovery with a
# reference recogniser) live in tests/test_speech_pipeline.py and run under pytest via scripts/verify.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/filo-audio-test.XXXXXX)"
FAILED=0

echo "== helper compiles"
if swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$OUT/filo-helper" "$ROOT"/helper/Sources/*.swift \
     -framework Cocoa -framework Carbon -framework Speech -framework AVFoundation 2> "$OUT/compile.log"; then
  echo "  ok: helper"
else
  echo "  FAIL: the helper does not compile"; grep error "$OUT/compile.log" | head; FAILED=1
fi

echo "== segmenter, pre-roll ring, tap core, endpointing, debug dump (synthetic signals)"
if swiftc -O -swift-version 5 -parse-as-library -o "$OUT/segmenter_cli" \
     "$ROOT"/helper/Sources/{AudioSegmenter,AudioTapCore,CaptureAnalyzer,Log}.swift "$ROOT/helper/Tests/segmenter_cli.swift" \
     -framework AVFoundation 2> "$OUT/cli_compile.log"; then
  "$OUT/segmenter_cli" selftest 2>/dev/null | tee "$OUT/selftest.log" | grep -E "FAIL|checks"
  grep -q "all segmenter checks passed" "$OUT/selftest.log" || FAILED=1
else
  echo "  FAIL: the segmenter test harness does not compile"; grep error "$OUT/cli_compile.log" | head; FAILED=1
fi

if [[ "$FAILED" -eq 0 ]]; then echo "AUDIO TESTS PASSED"; else echo "AUDIO TESTS FAILED (see $OUT)"; exit 1; fi
