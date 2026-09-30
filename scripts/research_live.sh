#!/bin/zsh
# Live checks for the research agent (real NVIDIA NIM + real wikis). Skips without NVIDIA_API_KEY.
#   scripts/research_live.sh                      smoke test
#   scripts/research_live.sh --bench              latency table on sample questions
#   scripts/research_live.sh --bench --models nvidia/nemotron-3-super-120b-a12b
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/find_godot.sh"
"$GODOT" --headless --path "$ROOT/app" --import >/dev/null 2>&1 || true
exec "$GODOT" --headless --path "$ROOT/app" -s tests/research_live.gd -- "$@"
