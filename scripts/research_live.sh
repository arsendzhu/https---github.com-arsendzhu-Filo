#!/bin/zsh
# Live checks for the research agent. The only live entry point is scripts/bench_live.py (it enforces the
# request budget and rate limit and never reads .env); this wrapper is kept for muscle memory.
#   NVIDIA_API_KEY=... scripts/research_live.sh --smoke | --bench ...
exec python3 "$(cd "$(dirname "$0")" && pwd)/bench_live.py" "$@"
