#!/usr/bin/env python3
"""Filo doctor: checks the setup and prints a clear PASS / FAIL list.

    python3 scripts/doctor.py [--offline] [--no-dotenv] [--nim-base URL] [--wiki-url URL] [--quick]

Checks: Godot and the project, the helper app (built, self-test), the full-screen overlay extension, a
microphone, an API key (whether one exists - it is NEVER printed), the NVIDIA model list and that the
configured models are in it, the game wikis, whether Filo is running (the helper bridge), the voice
(Kokoro / system), and settings.json. Exit code 1 if anything FAILs (WARN and SKIP do not fail).

  --offline      no network at all (skips the model list and the wikis)
  --no-dotenv    do not look inside .env for key names (the environment is still checked)
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = []


def report(status: str, name: str, detail: str = "", hint: str = "") -> None:
    RESULTS.append(status)
    print("[%-4s] %-34s %s" % (status, name, detail))
    if hint and status in ("FAIL", "WARN"):
        print("       -> %s" % hint)


def find_godot() -> str:
    for c in (os.environ.get("GODOT_BIN", ""), "/Applications/Godot.app/Contents/MacOS/Godot", shutil.which("godot") or "", shutil.which("godot4") or ""):
        if c and os.path.isfile(c):
            return c
    return ""


def run(cmd, timeout=90, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


def key_names_in_dotenv(path: str) -> set:
    """Names of the KEY=... lines only; the values are never read into a variable."""
    names = set()
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(\S)", line)
                if m and not line.strip().startswith("#"):
                    names.add(m.group(1))
    except OSError:
        pass
    return names


def http_json(url: str, headers=None, timeout=12):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": "Filo-doctor/0.1"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read().decode("utf-8", "replace"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Filo setup check")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--no-dotenv", action="store_true")
    ap.add_argument("--nim-base", default="")
    ap.add_argument("--wiki-url", default="", help="check this one MediaWiki api.php instead of the configured wikis")
    ap.add_argument("--quick", action="store_true", help="skip importing the Godot project")
    args = ap.parse_args()
    print("Filo doctor - %s\n" % ROOT)

    godot = find_godot()
    probe = {}
    if not godot:
        report("FAIL", "Godot", "not found", "brew install --cask godot   (or set GODOT_BIN)")
    else:
        v = run([godot, "--version"], 20)
        report("PASS", "Godot", (v.stdout.strip() or "found") + "  (" + godot + ")")
        if not args.quick:
            imp = run([godot, "--headless", "--path", os.path.join(ROOT, "app"), "--import"], 120)
            bad = [ln for ln in (imp.stdout + imp.stderr).splitlines() if "SCRIPT ERROR" in ln or "Parse Error" in ln]
            report("FAIL" if bad else "PASS", "Project loads", (bad[0].strip() if bad else "no script errors"), "run scripts/test.sh for details")
        pr = run([godot, "--headless", "--path", os.path.join(ROOT, "app"), "-s", "tests/doctor_probe.gd"], 60)
        m = re.search(r"DOCTOR_PROBE (\{.*\})", pr.stdout)
        if m:
            probe = json.loads(m.group(1))
        else:
            report("WARN", "Configuration", "could not read the configuration", "check config.json is valid JSON")

    # helper + overlay extension
    helper = os.path.join(ROOT, "helper", "build", "Filo Helper.app", "Contents", "MacOS", "filo-helper")
    if not os.path.isfile(helper):
        report("FAIL", "Helper app", "not built", "scripts/build_helper.sh")
    else:
        st = run([helper, "--test-matcher"], 30)
        report("PASS" if st.returncode == 0 else "FAIL", "Helper app", "built; wake-word matcher self-test %s" % ("passed" if st.returncode == 0 else "FAILED"), "scripts/build_helper.sh")
    ext = os.path.join(ROOT, "app", "native", "libfilo_overlay.dylib")
    report("PASS" if os.path.isfile(ext) else "WARN", "Full-screen overlay extension", "built" if os.path.isfile(ext) else "not built", "scripts/build_native.sh (needed to float over full-screen apps)")

    # microphone
    inputs = []
    if sys.platform == "darwin":
        try:
            sp = run(["system_profiler", "SPAudioDataType", "-json"], 30)
            for grp in json.loads(sp.stdout).get("SPAudioDataType", []):
                for item in grp.get("_items", []):
                    if item.get("coreaudio_device_input") or item.get("coreaudio_input_source"):
                        inputs.append(item.get("_name", "?"))
        except Exception:
            pass
    if inputs:
        report("PASS", "Microphone", "%d input device(s): %s" % (len(inputs), ", ".join(inputs[:3])), "")
        print("       (microphone and speech-recognition permission for 'Filo Helper' is asked on first use; it cannot be checked from here)")
    else:
        report("FAIL", "Microphone", "no input device found", "connect a microphone, or use the typed box (tap the hotkey)")

    # keys (never printed)
    have_nv = bool(os.environ.get("NVIDIA_API_KEY"))
    have_an = bool(os.environ.get("ANTHROPIC_API_KEY"))
    src = "environment" if (have_nv or have_an) else ""
    if not args.no_dotenv and not (have_nv or have_an):
        names = key_names_in_dotenv(os.path.join(ROOT, ".env"))
        have_nv = "NVIDIA_API_KEY" in names or "NIM_API_KEY" in names
        have_an = "ANTHROPIC_API_KEY" in names
        src = ".env" if (have_nv or have_an) else ""
    if have_nv or have_an:
        report("PASS", "API key", "%s present (from %s)" % ("NVIDIA_API_KEY" if have_nv else "ANTHROPIC_API_KEY", src))
    elif probe.get("has_nvidia_key") or probe.get("has_anthropic_key"):
        report("PASS", "API key", "present (from the app's own configuration)")
    else:
        report("WARN", "API key", "none found", "put NVIDIA_API_KEY in .env (free at build.nvidia.com); without it Filo answers from its notes only")

    # NVIDIA models
    models = probe.get("research_models", [])
    base = (args.nim_base or probe.get("nim_base") or "https://integrate.api.nvidia.com/v1").rstrip("/")
    key = os.environ.get("NVIDIA_API_KEY", "")
    if args.offline:
        report("SKIP", "NVIDIA model list", "offline")
    elif not (key or args.nim_base):
        report("SKIP", "NVIDIA model list", "no key in the environment (the check sends the key, so it needs it there)")
    else:
        try:
            _, data = http_json(base + "/models", {"Authorization": "Bearer " + key, "User-Agent": "Filo-doctor/0.1"} if key else None)
            ids = {m.get("id") for m in data.get("data", [])}
            missing = [m for m in models if m not in ids]
            if missing:
                report("WARN", "NVIDIA model list", "reachable (%d models); NOT listed: %s" % (len(ids), ", ".join(missing)),
                       "edit research.models in config.json (free NIM models are removed without notice); Filo skips missing ones")
            else:
                report("PASS", "NVIDIA model list", "reachable (%d models); all %d configured models are listed" % (len(ids), len(models)))
        except Exception as e:
            report("FAIL", "NVIDIA model list", "not reachable (%s)" % type(e).__name__, "check the internet connection and the base URL")

    # wikis
    wikis = {"custom": args.wiki_url} if args.wiki_url else probe.get("wikis", {})
    if args.offline:
        report("SKIP", "Game wikis", "offline")
    else:
        bad = []
        for game, url in list(wikis.items())[:8]:
            try:
                _, data = http_json(url + "?action=query&meta=siteinfo&format=json")
                if not data.get("query", {}).get("general", {}).get("sitename"):
                    bad.append(game)
            except Exception:
                bad.append(game)
        if not wikis:
            report("WARN", "Game wikis", "none configured", "research.wikis in config.json")
        elif bad:
            report("WARN", "Game wikis", "%d of %d not reachable: %s" % (len(bad), len(wikis), ", ".join(bad)), "the wiki may be down or its address changed (research.wikis)")
        else:
            report("PASS", "Game wikis", "%d reachable" % len(wikis))

    # is Filo running?
    port = int(probe.get("helper_port", 47821))
    s = socket.socket()
    s.settimeout(0.4)
    running = s.connect_ex(("127.0.0.1", port)) == 0
    s.close()
    report("PASS" if running else "INFO", "Filo running", "listening on port %d" % port if running else "not running (start it with scripts/run.sh)")

    # voice
    kokoro = os.path.isfile(os.path.join(ROOT, "tts", "venv", "bin", "python3")) and os.path.isfile(os.path.join(ROOT, "tts", "models", "kokoro-v1.0.onnx"))
    say = shutil.which("say") is not None
    if kokoro:
        report("PASS", "Voice", "Kokoro neural voice installed" + (" (+ system voice)" if say else ""))
    elif say:
        report("WARN", "Voice", "system voice only", "scripts/setup_voice.sh installs the far more natural Kokoro voice (~340 MB)")
    else:
        report("FAIL", "Voice", "no text-to-speech available", "scripts/setup_voice.sh")

    # settings file
    sp = probe.get("settings_path", os.path.join(ROOT, "settings.json"))
    if os.path.isfile(sp):
        try:
            json.load(open(sp))
            report("PASS", "settings.json", "valid")
        except ValueError:
            report("WARN", "settings.json", "is not valid JSON", "Filo will set it aside as settings.json.corrupt and use the defaults")
    else:
        report("PASS", "settings.json", "not created yet (defaults)")

    fails = RESULTS.count("FAIL")
    warns = RESULTS.count("WARN")
    print("\n%s  (%d passed, %d warnings, %d failed)" % ("ALL GOOD" if not fails and not warns else ("NEEDS ATTENTION" if fails else "OK WITH WARNINGS"), RESULTS.count("PASS"), warns, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
