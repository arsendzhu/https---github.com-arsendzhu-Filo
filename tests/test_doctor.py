"""scripts/doctor.py: a clear PASS/FAIL list, exit code, and it never prints a key. Network checks run against the
local mock server (scripts/mock_api.py), never a live API."""
import os
import re
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCTOR = os.path.join(ROOT, "scripts", "doctor.py")
FAKE_KEY = "nvapi-" + "FAKE-" * 8          # built at runtime: no key-like literal in the repo


def run(args, env_extra=None):
    env = {k: v for k, v in os.environ.items() if k not in ("NVIDIA_API_KEY", "ANTHROPIC_API_KEY")}
    env.update(env_extra or {})
    return subprocess.run([sys.executable, DOCTOR, *args], env=env, capture_output=True, text=True, timeout=300)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def test_offline_report_format_and_exit_code():
    r = run(["--offline", "--no-dotenv", "--quick"])
    lines = [l for l in r.stdout.splitlines() if l.startswith("[")]
    assert len(lines) >= 8, r.stdout
    assert all(re.match(r"\[(PASS|FAIL|WARN|SKIP|INFO)\s*\]", l) for l in lines)
    assert "[SKIP] NVIDIA model list" in r.stdout and "[SKIP] Game wikis" in r.stdout        # offline means offline
    assert re.search(r"\(\d+ passed, \d+ warnings, \d+ failed\)", r.stdout)
    assert (r.returncode == 1) == ("[FAIL]" in r.stdout)                                     # exit 1 exactly when something failed


def test_the_key_is_reported_present_but_never_printed():
    r = run(["--offline", "--no-dotenv", "--quick"], {"NVIDIA_API_KEY": FAKE_KEY})
    assert FAKE_KEY not in r.stdout and FAKE_KEY not in r.stderr
    assert re.search(r"\[PASS\] API key\s+NVIDIA_API_KEY present \(from environment\)", r.stdout)


def test_model_list_and_wikis_against_the_local_mock():
    port = free_port()
    mock = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "mock_api.py"), "--port", str(port)], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        r = run(["--no-dotenv", "--quick", "--nim-base", "http://127.0.0.1:%d/v1" % port, "--wiki-url", "http://127.0.0.1:%d/api.php" % port], {"NVIDIA_API_KEY": FAKE_KEY})
        assert FAKE_KEY not in r.stdout
        # the mock lists three fake models, so the configured ones are reported as missing (a WARN with a hint), not a crash
        assert re.search(r"\[WARN\] NVIDIA model list\s+reachable \(3 models\); NOT listed: .*nemotron", r.stdout), r.stdout
        assert "research.models" in r.stdout
        assert re.search(r"\[PASS\] Game wikis\s+1 reachable", r.stdout), r.stdout
    finally:
        mock.terminate()
        mock.wait(timeout=5)


def test_a_dead_endpoint_is_a_clear_failure():
    r = run(["--no-dotenv", "--quick", "--nim-base", "http://127.0.0.1:%d/v1" % free_port(), "--wiki-url", "http://127.0.0.1:%d/api.php" % free_port()], {"NVIDIA_API_KEY": FAKE_KEY})
    assert re.search(r"\[FAIL\] NVIDIA model list\s+not reachable", r.stdout), r.stdout
    assert r.returncode == 1 and "NEEDS ATTENTION" in r.stdout
