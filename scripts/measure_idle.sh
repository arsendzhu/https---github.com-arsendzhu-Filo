#!/bin/zsh
# Idle cost of the overlay: launches the app asleep (no helper, muted, no greeting) and samples its CPU % and
# resident memory once a second. Usage: scripts/measure_idle.sh [seconds] [extra app args...]
# Prints the mean CPU %, the peak and the resident memory in MB. GPU load is not sampled here (no public API).
set -uo pipefail
ROOT="${FILO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"        # FILO_ROOT: measure another checkout (e.g. the original commit)
source "$(cd "$(dirname "$0")" && pwd)/find_godot.sh"
SECS="${1:-25}"; shift 2>/dev/null || true
export FILO_SETTINGS_PATH="$(mktemp -u /tmp/filo-idle-settings.XXXXXX).json"
# fake keys and closed local ports: this must never reach a real API (the app loads .env by itself)
FILO_NIM_BASE=http://127.0.0.1:9/v1 FILO_API_BASE=http://127.0.0.1:9 FILO_WIKI_BASE=http://127.0.0.1:9 NVIDIA_API_KEY=nvapi-test ANTHROPIC_API_KEY=test-key FILO_PROVIDER=none "$GODOT" --path "$ROOT/app" -- --no-helper --mute --no-greet --quit-after $((SECS + 12)) "$@" > /tmp/filo-idle.log 2>&1 &
APP=$!
sleep 9      # start-up (window, shaders, first-frame warm-up) is not "idle"
PID=$(pgrep -n -f "Godot.*--path $ROOT/app" || echo $APP)
samples=(); mem=0
for i in $(seq 1 $SECS); do
  line=$(ps -o %cpu=,rss= -p "$PID" 2>/dev/null)
  [[ -z "$line" ]] && break
  samples+=("$(echo $line | awk '{print $1}')")
  mem=$(echo $line | awk '{print $2}')
  sleep 1
done
kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
python3 - "${samples[@]}" <<PY
import sys
v=[float(x) for x in sys.argv[1:]]
print("idle samples: %d, mean CPU %.1f %%, peak %.1f %%, resident memory %.0f MB" % (len(v), sum(v)/max(1,len(v)), max(v) if v else 0, $mem/1024.0))
PY
