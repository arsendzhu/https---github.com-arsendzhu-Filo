#!/usr/bin/env python3
"""Live benchmark of the NIM research path (latency + key-term accuracy on a fixed 8-question set).

    NVIDIA_API_KEY=... python3 scripts/bench_live.py [--out logs/bench_final.json] [--label final]
                       [--no-prefetch] [--no-stream] [--models id1,id2] [--limit N] [--smoke] [--dry-run]

This is the ONLY place that may make live NVIDIA requests. Rules it enforces:
  * it runs only when NVIDIA_API_KEY is set in the environment; without it, it prints SKIPPED and exits 0
    (it never reads .env or any other file for the key);
  * at most MAX_REQUESTS (20) requests per run and MAX_PER_MINUTE (30) per minute - enforced inside the
    app's NIM client through FILO_NIM_MAX_REQUESTS / FILO_NIM_MAX_RPM, and re-checked from the results;
  * the key is passed through the environment only and scrubbed from everything this script prints or saves.

The benchmark itself is app/tests/research_live.gd (the real ResearchAgent: prefetch, streaming, keep-alive
connection, model chain) run headless; the 8 questions are the `bench` entries of tests/golden_questions.json
(2 per game: Terraria, Sekiro, Dark Souls, Crimson Desert). Results: p50/p95 of the total time and of the
first model response, mean key-term accuracy, requests used. If logs/bench_baseline.json exists the two are
compared and a slower or less accurate result is reported plainly.
"""
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_REQUESTS = 20
MAX_PER_MINUTE = 30


def find_godot() -> str:
    for c in (os.environ.get("GODOT_BIN", ""), "/Applications/Godot.app/Contents/MacOS/Godot", "godot", "godot4"):
        if c and (os.path.isfile(c) or subprocess.run(["which", c], capture_output=True).returncode == 0):
            return c
    return ""


def build_command(godot: str, args) -> list:
    cmd = [godot, "--headless", "--path", os.path.join(ROOT, "app"), "-s", "tests/research_live.gd", "--"]
    cmd += ["--smoke"] if args.smoke else ["--bench", "--json", args.out, "--label", args.label]
    if args.no_prefetch:
        cmd.append("--no-prefetch")
    if args.no_stream:
        cmd.append("--no-stream")
    if args.models:
        cmd += ["--models", args.models]
    if args.limit:
        cmd += ["--limit", str(args.limit)]
    return cmd


def build_env(key: str) -> dict:
    env = dict(os.environ)
    env["NVIDIA_API_KEY"] = key
    env["FILO_NIM_MAX_REQUESTS"] = str(MAX_REQUESTS)
    env["FILO_NIM_MAX_RPM"] = str(MAX_PER_MINUTE)
    env["FILO_LIVE_VIA_BENCH"] = "1"
    env["FILO_PROVIDER"] = "nim"
    # nothing else may be reached: a Claude key from the environment would otherwise make its fallback live
    env["ANTHROPIC_API_KEY"] = ""
    return env


def scrub(text: str, key: str) -> str:
    return text.replace(key, "***") if key else text


def compare(new: dict, base_path: str) -> None:
    if not os.path.exists(base_path):
        print("(no baseline at %s to compare with)" % os.path.relpath(base_path, ROOT))
        return
    base = json.load(open(base_path))["summary"]
    s = new["summary"]
    print("\nvs baseline (%s):" % json.load(open(base_path)).get("label", "?"))
    for k in ("total_ms_p50", "total_ms_p95", "first_response_ms_p50", "keyword_accuracy"):
        b, n = base.get(k), s.get(k)
        if b in (None, -1) or n in (None, -1):
            continue
        change = (n - b) / b * 100 if b else 0
        worse = (n > b) if k.endswith("_ms_p50") or k.endswith("_ms_p95") else (n < b)
        print("  %-24s %8s -> %-8s (%+.0f %%)%s" % (k, round(b, 3), round(n, 3), change, "   WORSE" if worse and abs(change) > 5 else ""))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "logs", "bench_final.json"))
    ap.add_argument("--label", default="final")
    ap.add_argument("--no-prefetch", action="store_true")
    ap.add_argument("--no-stream", action="store_true")
    ap.add_argument("--models", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--smoke", action="store_true", help="just check the models are listed and that tool_choice=required is accepted")
    ap.add_argument("--dry-run", action="store_true", help="print what would run (no request is made)")
    args = ap.parse_args()

    key = os.environ.get("NVIDIA_API_KEY", "").strip()
    if not key:
        print("SKIPPED: NVIDIA_API_KEY is not set in the environment (this script never reads .env). "
              "Run: NVIDIA_API_KEY=... python3 scripts/bench_live.py --label baseline --out logs/bench_baseline.json")
        return 0
    godot = find_godot()
    if not godot:
        print("Godot not found (set GODOT_BIN)")
        return 1
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    cmd = build_command(godot, args)
    if args.dry_run:
        print("would run:", " ".join(cmd))
        print("limits: at most %d requests, %d per minute; key passed via the environment only" % (MAX_REQUESTS, MAX_PER_MINUTE))
        return 0
    res = subprocess.run(cmd, env=build_env(key), capture_output=True, text=True, timeout=900)
    out = scrub(res.stdout, key)
    lines = [l for l in out.splitlines() if not l.startswith(("Godot Engine", "ERROR: ", "   at:")) and "ObjectDB" not in l and "resources still in use" not in l]
    print("\n".join(lines[-40:]))
    if res.returncode != 0:
        print(scrub(res.stderr, key)[-1500:])
        return res.returncode
    if not args.smoke and os.path.exists(args.out):
        data = json.load(open(args.out))
        used = data["summary"].get("nim_requests", 0)
        if used > MAX_REQUESTS:
            print("BUDGET EXCEEDED: %d requests (limit %d)" % (used, MAX_REQUESTS))
            return 1
        base_path = os.path.join(ROOT, "logs", "bench_baseline.json")
        if os.path.abspath(args.out) != os.path.abspath(base_path):
            compare(data, base_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
