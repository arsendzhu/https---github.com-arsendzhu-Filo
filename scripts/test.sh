#!/bin/zsh
# Phase 0 test suite:
#   1. native overlay extension + import + headless unit tests + helper matcher self-test
#   2. end-to-end runs with the scripted fake helper and the offline mock services:
#      a) push-to-talk, mock Claude, tap dismisses
#      b) wake word, answer, "anything else?", follow-up question, "bye filo"
#      c) NVIDIA NIM + Wikipedia fallback (both mocked)
#   2d) the same wake/follow-up/bye loop, unmuted, through the REAL local
#       Kokoro voice — the one path that was never exercised by a) - c), and
#       exactly where a multi-request TTS pipeline previously let a class of
#       hang/gap bug slip through untested
#   3. showcase run with frame captures of every animation state
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/find_godot.sh"
OUT="${FILO_TEST_OUT:-$(mktemp -d /tmp/filo-test.XXXXXX)}"
mkdir -p "$OUT"
PY="$(command -v python3)"
FAILED=0
echo "Test output: $OUT"

expect() {  # expect <logfile> <pattern> <description>
  if grep -q -- "$2" "$1"; then echo "  ok: $3"; else echo "  FAIL: $3 (missing '$2' in $1)"; FAILED=1; fi
}
no_script_errors() {
  if grep -q "SCRIPT ERROR" "$1"; then echo "  FAIL: script errors in $1"; grep -A3 "SCRIPT ERROR" "$1" | head -8; FAILED=1; fi
}

echo "== 1/4 native overlay extension + import + unit tests"
[[ -f "$ROOT/app/native/libfilo_overlay.dylib" ]] || "$ROOT/scripts/build_native.sh" >/dev/null
"$GODOT" --headless --path "$ROOT/app" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT/app" -s tests/run_tests.gd > "$OUT/unit.log" 2>&1
grep -E "passed|FAIL" "$OUT/unit.log"
expect "$OUT/unit.log" ", 0 failed" "unit tests"
no_script_errors "$OUT/unit.log"

HELPER_BIN="$ROOT/helper/build/Filo Helper.app/Contents/MacOS/filo-helper"
if [[ -x "$HELPER_BIN" ]]; then
  echo "== helper wake-word matcher self-test"
  "$HELPER_BIN" --test-matcher > "$OUT/matcher.log" 2>&1 && echo "  ok: matcher" || { echo "  FAIL: matcher (see $OUT/matcher.log)"; FAILED=1; }
fi

"$PY" "$ROOT/scripts/mock_api.py" --port 8787 2>"$OUT/mock_api.log" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null || true' EXIT
for _ in {1..50}; do curl -s -o /dev/null http://127.0.0.1:8787/v1/models && break; sleep 0.2; done   # mock is up

echo "== 2a/4 push-to-talk (mock Claude + fake helper, muted)"
FILO_PROVIDER=anthropic ANTHROPIC_API_KEY=test-key "$GODOT" --path "$ROOT/app" -- \
  --api-base http://127.0.0.1:8787 --port 47899 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --tap-after 3" \
  --mute --no-greet --quit-after 30 --verbose > "$OUT/e2e.log" 2>&1
expect "$OUT/e2e.log" "Helper connected" "helper connected over the bridge"
expect "$OUT/e2e.log" "state -> LISTENING" "hold started listening"
expect "$OUT/e2e.log" "QUESTION: I'm stuck on the Guardian Ape" "question received from helper"
expect "$OUT/e2e.log" "web fallback off" "retrieval confident, no web fallback"
expect "$OUT/e2e.log" "ANSWER (claude-opus-5)" "answer produced via mock Claude"
expect "$OUT/e2e.log" "SOURCE: Guardian Ape" "source cited from notes"
expect "$OUT/e2e.log" "state -> ANSWERING" "answer spoken (simulated)"
expect "$OUT/e2e.log" "state -> SLEEPING" "tap while awake dismissed the mascot"
expect "$OUT/e2e.log" "Filo quitting" "clean exit"
expect "$OUT/mock_api.log" "fallbacks=default beta=server-side-fallback-2026-07-01" "refusal fallbacks sent to the API"
no_script_errors "$OUT/e2e.log"

echo "== 2b/4 wake word, follow-up, bye (mock Claude + fake helper, muted)"
FILO_PROVIDER=anthropic ANTHROPIC_API_KEY=test-key "$GODOT" --path "$ROOT/app" -- \
  --api-base http://127.0.0.1:8787 --port 47897 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --followup 'what about its second phase'" \
  --mute --no-greet --quit-after 45 --verbose > "$OUT/e2e_wake.log" 2>&1
expect "$OUT/e2e_wake.log" "Wake word heard" "wake word event handled"
expect "$OUT/e2e_wake.log" "state -> LISTENING" "wake word started listening"
expect "$OUT/e2e_wake.log" "ANSWER (claude-opus-5)" "answer produced after wake word"
expect "$OUT/e2e_wake.log" "wake_pause" "wake listening paused while speaking"
expect "$OUT/e2e_wake.log" "Reprompt:" "Filo re-prompted after the answer"
expect "$OUT/e2e_wake.log" "(follow-up)" "follow-up listening opened without a wake phrase"
expect "$OUT/e2e_wake.log" "QUESTION: what about its second phase" "follow-up question answered"
expect "$OUT/e2e_wake.log" "Bye heard" "bye filo ended the conversation"
expect "$OUT/e2e_wake.log" "state -> SLEEPING" "dismissed after bye"
no_script_errors "$OUT/e2e_wake.log"

echo "== 2c/4 NVIDIA NIM: research fails (dead model) -> the existing Wikipedia fallback still answers (both mocked, offline)"
echo '{"research": {"models": [{"id": "dead-model"}], "warmup_probe": false, "claude_fallback": false}}' > "$OUT/dead_research.json"
FILO_PROVIDER=nim NVIDIA_API_KEY=nvapi-test "$GODOT" --path "$ROOT/app" -- \
  --config "$OUT/dead_research.json" --nim-base http://127.0.0.1:8787/v1 --wiki-base http://127.0.0.1:8787 --port 47896 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --question 'Who is Ganon in Zelda?'" \
  --mute --no-greet --quit-after 35 --verbose > "$OUT/e2e_wiki.log" 2>&1
expect "$OUT/e2e_wiki.log" "LLM: NVIDIA NIM" "NIM provider selected"
expect "$OUT/e2e_wiki.log" "route: tool loop failed" "the research path failed (410) instead of answering (log line renamed with the routing work)"
expect "$OUT/e2e_wiki.log" "using the standard fallback" "...and handed over to the standard fallback"
expect "$OUT/e2e_wiki.log" "asking Wikipedia" "low notes confidence triggered Wikipedia"
expect "$OUT/e2e_wiki.log" "Wikipedia: 2 page(s): Ganon, The Legend of Zelda" "two summaries fetched, disambiguation skipped"
expect "$OUT/e2e_wiki.log" "ANSWER (" "NIM answered with the Wikipedia passages"
expect "$OUT/e2e_wiki.log" "SOURCE: Ganon — https://en.wikipedia.org/wiki/Ganon" "Wikipedia source shown"
# the game is now taken from the question ("in Zelda"), not blindly from the loaded Sekiro profile
expect "$OUT/mock_api.log" "mock_wiki: search 'Zelda Who is Ganon in Zelda?' ua='Filo/0.1" "search biased with the game named in the question and a proper User-Agent"
no_script_errors "$OUT/e2e_wiki.log"

KOKORO_PY="$ROOT/tts/venv/bin/python3"
if [[ -x "$KOKORO_PY" && -f "$ROOT/tts/models/kokoro-v1.0.onnx" ]]; then
  echo "== 2d/4 wake word, follow-up, bye — REAL Kokoro voice, unmuted"
  pkill -f kokoro_server.py 2>/dev/null || true
  FILO_PROVIDER=anthropic ANTHROPIC_API_KEY=test-key "$GODOT" --path "$ROOT/app" -- \
    --api-base http://127.0.0.1:8787 --port 47892 --tts-provider kokoro \
    --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --wait-url http://127.0.0.1:47823/health --followup 'what about its second phase'" \
    --no-greet --quit-after 100 --verbose > "$OUT/e2e_kokoro.log" 2>&1
  expect "$OUT/e2e_kokoro.log" "Kokoro voice ready" "real Kokoro voice server came up"
  expect "$OUT/e2e_kokoro.log" "Reprompt:" "Filo re-prompted after a real spoken answer"
  expect "$OUT/e2e_kokoro.log" "(follow-up)" "follow-up listening opened without a wake phrase"
  expect "$OUT/e2e_kokoro.log" "QUESTION: what about its second phase" "follow-up question answered"
  expect "$OUT/e2e_kokoro.log" "Bye heard" "bye filo ended the conversation"
  expect "$OUT/e2e_kokoro.log" "state -> SLEEPING" "dismissed after bye"
  KOKORO_REQUESTS=$(grep -c "Kokoro HTTP 200" "$OUT/e2e_kokoro.log")
  echo "  Kokoro HTTP requests: $KOKORO_REQUESTS (one per spoken line: answer, reprompt, answer, reprompt, bye)"
  if [[ "$KOKORO_REQUESTS" -ne 5 ]]; then echo "  FAIL: expected exactly 5 Kokoro requests (one per utterance, no per-sentence splitting)"; FAILED=1; fi
  if grep -q "Speech watchdog" "$OUT/e2e_kokoro.log"; then echo "  FAIL: speech watchdog fired — something hung and needed forcing"; FAILED=1; fi
  no_script_errors "$OUT/e2e_kokoro.log"
  pkill -f kokoro_server.py 2>/dev/null || true
else
  echo "== 2d/4 skipped (Kokoro not installed — run scripts/setup_voice.sh)"
fi

echo "== 2e/4 research (model-driven loop, prefetch off): NIM tool-calling loop over a mock game wiki; a dead model falls back (offline)"
cat > "$OUT/research_config.json" <<JSON
{"research": {"models": [{"id": "dead-model"}, {"id": "live-model"}], "claude_fallback": false, "prefetch": false,
  "wikis": {"dark souls": {"aliases": ["dark souls"], "base_url": "http://127.0.0.1:8787", "api_path": "/api.php", "name": "Dark Souls wiki"}}}}
JSON
FILO_PROVIDER=nim NVIDIA_API_KEY=nvapi-test "$GODOT" --path "$ROOT/app" -- \
  --config "$OUT/research_config.json" --nim-base http://127.0.0.1:8787/v1 --port 47895 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --question 'Where do I find the Lordvessel in Dark Souls?'" \
  --mute --no-greet --quit-after 40 --verbose > "$OUT/e2e_research.log" 2>&1
expect "$OUT/e2e_research.log" "Research (tool-calling) chain: dead-model → live-model" "model chain loaded from config"
expect "$OUT/e2e_research.log" "primary model 'dead-model' is not responding" "start-up warm-up found the dead model and marked it down"
expect "$OUT/e2e_research.log" "route: tool loop" "no confident local answer entered the tool loop (log line renamed with the routing work)"
expect "$OUT/e2e_research.log" "Research done: model=live-model rounds=3 tools=2" "wiki_search -> wiki_page -> answer on the live model"
expect "$OUT/e2e_research.log" "ANSWER (live-model, web): According to the Dark Souls wiki, you get the Lordvessel from Frampt" "spoken answer came from the fetched page"
expect "$OUT/e2e_research.log" "SOURCE: Lordvessel — http://127.0.0.1:8787/wiki/Lordvessel" "the page that was read is cited"
expect "$OUT/mock_api.log" "mock_gamewiki: parse 'Lordvessel'" "wiki page was fetched through the existing MediaWiki client"
expect "$OUT/mock_api.log" "mock_nim_tools: model=live-model tool_choice=auto last=tool" "tool results were sent back to the model"
if grep -q "SECRET REASONING\|<think>\|https://darksouls" "$OUT/e2e_research.log"; then
  if grep -E "ANSWER|Filo\] SOURCE" "$OUT/e2e_research.log" | grep -q "SECRET REASONING\|<think>\|https://darksouls"; then echo "  FAIL: reasoning text or a URL reached the spoken answer"; FAILED=1; else echo "  ok: reasoning and URLs stayed out of the answer"; fi
else echo "  ok: reasoning and URLs stayed out of the answer"; fi
no_script_errors "$OUT/e2e_research.log"

echo "== 2f/4 the reported bug (prefetch off): a game outside the notes (Terraria) must reach the tool loop even when the model will not call tools itself"
cat > "$OUT/terraria_config.json" <<JSON
{"research": {"models": [{"id": "lazy-model"}], "claude_fallback": false, "warmup_probe": false, "prefetch": false,
  "wikis": {"terraria": "http://127.0.0.1:8787"}}}
JSON
FILO_PROVIDER=nim NVIDIA_API_KEY=nvapi-test "$GODOT" --path "$ROOT/app" -- \
  --config "$OUT/terraria_config.json" --nim-base http://127.0.0.1:8787/v1 --port 47894 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --question 'How do I beat the Eye of Cthulhu in Terraria?'" \
  --mute --no-greet --quit-after 40 --verbose > "$OUT/e2e_terraria.log" 2>&1
expect "$OUT/e2e_terraria.log" "route: tool loop" "the Terraria question was routed to the tool loop (not answered from the loaded Sekiro notes)"
expect "$OUT/e2e_terraria.log" "game='Terraria'" "the game was detected from the question"
expect "$OUT/e2e_terraria.log" "rejected tool_choice=required" "a model that rejects tool_choice=required is handled"
expect "$OUT/e2e_terraria.log" "answered without a tool call" "a model that answers from memory is overruled"
expect "$OUT/e2e_terraria.log" "Tool call: wiki_search({\"game\":\"Terraria\",\"query\":\"Eye of Cthulhu\"})" "the search ran anyway, with a clean query"
expect "$OUT/mock_api.log" "mock_gamewiki: query 'Eye of Cthulhu'" "the game's wiki API was queried"
expect "$OUT/e2e_terraria.log" "ANSWER (lazy-model, web): According to the Terraria wiki" "the spoken answer is grounded in the tool result, not the model's memory"
no_script_errors "$OUT/e2e_terraria.log"

echo "== 2h/4 speed: the default flow prefetches the wiki search + page, so ONE model call answers (offline)"
cat > "$OUT/prefetch_config.json" <<JSON
{"research": {"models": [{"id": "live-model"}], "claude_fallback": false, "warmup_probe": false,
  "wikis": {"dark souls": {"aliases": ["dark souls"], "base_url": "http://127.0.0.1:8787", "api_path": "/api.php", "name": "Dark Souls wiki"}}}}
JSON
FILO_PROVIDER=nim NVIDIA_API_KEY=nvapi-test "$GODOT" --path "$ROOT/app" -- \
  --config "$OUT/prefetch_config.json" --nim-base http://127.0.0.1:8787/v1 --port 47893 --tts-provider system \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --wake --question 'Where do I find the Lordvessel in Dark Souls?'" \
  --mute --no-greet --quit-after 40 --verbose > "$OUT/e2e_prefetch.log" 2>&1
expect "$OUT/e2e_prefetch.log" "Prefetch: wiki_search, wiki_page" "the wiki was searched and the top page read before the first model call"
expect "$OUT/e2e_prefetch.log" "Research done: model=live-model rounds=1 tools=2" "one model round trip answered (the model-driven loop needed three)"
expect "$OUT/e2e_prefetch.log" "ANSWER (live-model, web): According to the Dark Souls wiki, you get the Lordvessel from Frampt" "the answer comes from the prefetched page"
expect "$OUT/e2e_prefetch.log" "SOURCE: Lordvessel" "the prefetched page is cited"
expect "$OUT/mock_api.log" "mock_nim_tools: model=live-model tool_choice=auto last=tool" "the first model request already carried the tool results"
no_script_errors "$OUT/e2e_prefetch.log"

echo "== 2g/4 UI controls + click-through + mute/typing over the real bridge (real scene, real helper process)"
rm -f "$OUT/ui_cmds.jsonl"
# fake keys + closed local ports: this run loads the project's config/.env like the app does, so nothing may
# be able to reach a real API (the only live calls allowed are scripts/bench_live.py's)
FILO_UI_TEST_LOG="$OUT/ui_cmds.jsonl" FILO_PROVIDER=anthropic ANTHROPIC_API_KEY=test-key NVIDIA_API_KEY=nvapi-test "$GODOT" --headless --path "$ROOT/app" -s tests/ui_tests.gd -- \
  --api-base http://127.0.0.1:9 --nim-base http://127.0.0.1:9/v1 --wiki-base http://127.0.0.1:9 \
  --helper-cmd "$PY" --helper-args "$ROOT/scripts/fake_helper.py --idle --log-commands $OUT/ui_cmds.jsonl" \
  --no-greet --mute --port 47890 --tts-provider system > "$OUT/ui.log" 2>&1
grep -E "ui tests|FAIL" "$OUT/ui.log"
expect "$OUT/ui.log" ", 0 failed" "UI controls, passthrough geometry and IPC round trips"
no_script_errors "$OUT/ui.log"

echo "== 3/4 showcase captures"
"$GODOT" --path "$ROOT/app" -- --showcase --capture-dir "$OUT/captures" --mute --no-helper --tts-provider system --quit-after 70 > "$OUT/showcase.log" 2>&1
COUNT=$(ls "$OUT/captures" 2>/dev/null | grep -c "_review.png")
echo "  captured $COUNT review frames in $OUT/captures"
if [[ "$COUNT" -lt 24 ]]; then echo "  FAIL: expected at least 24 review frames"; FAILED=1; fi
no_script_errors "$OUT/showcase.log"

echo "== 4/4 summary"

if [[ "$FAILED" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED (see $OUT)"; exit 1; fi
