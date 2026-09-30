#!/usr/bin/env bash
# scripts/verify.sh : the single pass/fail gate for the overnight run.
# PROTECTED: agents must not edit this file. overnight.sh restores it from a
# copy stored outside the repo before every run.
# Never calls the live NVIDIA API.
set -u
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1

FAIL=0
step() { printf '\n== %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
ok()   { printf 'ok: %s\n' "$1"; }

STATE_DIR="${OVERNIGHT_STATE_DIR:-$HOME/.filo_overnight}"
BASELINE_FILE="$STATE_DIR/baseline_test_count"

# Pick a python interpreter (prefer the project venv)
PY=""
for c in ".venv/bin/python" "venv/bin/python" "python3" "python"; do
  if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then PY="$c"; break; fi
done

# ---------------------------------------------------------------- required tests
step "Required regression tests exist"
REQUIRED=(
  test_unknown_game_still_uses_tools
  test_ui_controls_visible_on_launch
  test_passthrough_covers_controls
  test_vad_preroll_and_hangover
  test_speech_not_clipped
  test_barge_in_stops_tts
  test_followup_uses_session_context
  test_settings_persist_roundtrip
  test_golden_questions_eval
)
for name in "${REQUIRED[@]}"; do
  if grep -rIq --include='*.py' --include='*.gd' --include='*.cs' --include='*.sh' \
       --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv \
       --exclude='verify.sh' --exclude='OVERNIGHT.md' "$name" .; then
    ok "$name"
  else
    bad "missing required test: $name"
  fi
done

# ---------------------------------------------------------------- secrets
step "No API keys committed"
if git grep -IqE 'nvapi-[A-Za-z0-9_-]{20,}' -- . ':!scripts/verify.sh' 2>/dev/null; then
  bad "an nvapi- key appears in tracked files"
else
  ok "no nvapi- keys in tracked files"
fi

# ---------------------------------------------------------------- python
if [ -n "$PY" ] && { [ -d tests ] || ls ./*test*.py >/dev/null 2>&1 || [ -f pytest.ini ] || [ -f pyproject.toml ]; }; then
  step "Python compile check"
  if "$PY" -m compileall -q . -x '(\.venv|venv|node_modules|\.git)' >/dev/null 2>&1; then
    ok "compileall"
  else
    bad "python files do not compile"
  fi

  step "Python tests (pytest)"
  if "$PY" -m pytest --version >/dev/null 2>&1; then
    if "$PY" -m pytest -q -p no:cacheprovider; then ok "pytest passed"; else bad "pytest failed"; fi

    step "Test count has not dropped"
    COUNT=$("$PY" -m pytest --collect-only -q -p no:cacheprovider 2>/dev/null | grep -c '::')
    echo "collected tests: $COUNT"
    if [ -f "$BASELINE_FILE" ]; then
      BASE=$(cat "$BASELINE_FILE")
      if [ "$COUNT" -lt "$BASE" ]; then
        bad "test count dropped from $BASE to $COUNT"
      else
        ok "test count $COUNT >= baseline $BASE"
      fi
    else
      echo "no baseline yet (created by overnight.sh)"
    fi
  else
    bad "pytest is not installed in $PY"
  fi
else
  step "Python"
  echo "no python tests detected (skipped)"
fi

# ---------------------------------------------------------------- godot
GODOT="${GODOT_BIN:-}"
if [ -z "$GODOT" ]; then
  for c in godot godot4 /Applications/Godot.app/Contents/MacOS/Godot; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then GODOT="$c"; break; fi
  done
fi
PROJ=$(find . -name project.godot -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -1)
if [ -n "$PROJ" ]; then
  PROJ_DIR=$(dirname "$PROJ")
  step "Godot project"
  if [ -z "$GODOT" ]; then
    bad "project.godot found but no Godot binary (set GODOT_BIN)"
  else
    OUT=$(timeout 180 "$GODOT" --headless --path "$PROJ_DIR" --quit 2>&1)
    echo "$OUT" | tail -20
    if echo "$OUT" | grep -qE 'SCRIPT ERROR|Parse Error|Failed to load script'; then
      bad "Godot reported script errors"
    else
      ok "Godot project loads without script errors"
    fi
    if [ -f "$PROJ_DIR/addons/gut/gut_cmdln.gd" ]; then
      step "Godot GUT tests"
      if timeout 300 "$GODOT" --headless --path "$PROJ_DIR" -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit; then
        ok "GUT passed"
      else
        bad "GUT tests failed"
      fi
    else
      echo "no GUT addon; scene-level checks must live in the python tests or a script wired in below"
    fi
  fi
fi

# ---------------------------------------------------------------- optional project hook
if [ -x scripts/extra_checks.sh ]; then
  step "Project extra checks"
  if scripts/extra_checks.sh; then ok "extra checks"; else bad "extra checks failed"; fi
fi

# ---------------------------------------------------------------- manual test doc
step "Docs"
[ -f MANUAL_TESTS.md ] && ok "MANUAL_TESTS.md" || bad "MANUAL_TESTS.md missing"
[ -f PROGRESS.md ]     && ok "PROGRESS.md"     || bad "PROGRESS.md missing"

printf '\n'
if [ "$FAIL" -eq 0 ]; then echo "VERIFY: PASS"; exit 0; else echo "VERIFY: FAIL"; exit 1; fi
