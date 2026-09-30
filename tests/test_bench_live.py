"""scripts/bench_live.py must never make a live request unless the user provided a key, must stay inside its
request/rate budget, and must never print the key. (No test here contacts any API.)"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "bench_live.py")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import bench_live  # noqa: E402


def run(env_extra=None, args=()):
    env = {k: v for k, v in os.environ.items() if k not in ("NVIDIA_API_KEY",)}
    env.update(env_extra or {})
    return subprocess.run([sys.executable, SCRIPT, *args], env=env, capture_output=True, text=True, timeout=60)


def test_without_a_key_it_skips_and_does_nothing():
    r = run()
    assert r.returncode == 0
    assert "SKIPPED" in r.stdout and "never reads .env" in r.stdout


def test_limits_are_within_the_allowance():
    assert bench_live.MAX_REQUESTS <= 20
    assert bench_live.MAX_PER_MINUTE <= 30


def test_the_key_never_appears_in_output_and_the_limits_are_passed_on():
    fake = "nvapi-FAKE-KEY-FOR-TEST-ONLY-0123456789"
    r = run({"NVIDIA_API_KEY": fake}, ["--dry-run"])
    assert r.returncode == 0
    assert fake not in r.stdout and fake not in r.stderr
    assert "at most 20 requests, 30 per minute" in r.stdout
    env = bench_live.build_env(fake)
    assert env["FILO_NIM_MAX_REQUESTS"] == "20" and env["FILO_NIM_MAX_RPM"] == "30" and env["FILO_LIVE_VIA_BENCH"] == "1"
    assert env["ANTHROPIC_API_KEY"] == ""                       # no other provider can be reached
    assert bench_live.scrub("token %s end" % fake, fake) == "token *** end"


def test_the_godot_side_refuses_live_requests_without_the_bench_flag():
    godot = bench_live.find_godot()
    assert godot, "Godot not found"
    env = {k: v for k, v in os.environ.items() if k != "FILO_LIVE_VIA_BENCH"}
    env["NVIDIA_API_KEY"] = "nvapi-fake"
    r = subprocess.run([godot, "--headless", "--path", os.path.join(ROOT, "app"), "-s", "tests/research_live.gd", "--", "--smoke"],
                       env=env, capture_output=True, text=True, timeout=60)
    assert "REFUSED" in r.stdout


def test_bench_questions_are_two_per_game():
    import json
    data = json.load(open(os.path.join(ROOT, "tests", "golden_questions.json")))
    bench = [q for q in data["questions"] if q["bench"]]
    assert len(bench) == 8
    for game in ("Terraria", "Sekiro: Shadows Die Twice", "Dark Souls", "Crimson Desert"):
        assert sum(1 for q in bench if q["game"] == game) == 2
