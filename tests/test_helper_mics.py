"""The helper lists the Mac's real audio inputs through CoreAudio (no permission needed, no network, and it must
exit without ever connecting to a running Filo)."""
import os
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "logs", "build")


def _build_helper() -> str:
    os.makedirs(BUILD, exist_ok=True)
    out = os.path.join(BUILD, "filo-helper-test")
    srcs = sorted(os.path.join(ROOT, "helper", "Sources", f) for f in os.listdir(os.path.join(ROOT, "helper", "Sources")) if f.endswith(".swift"))
    if not os.path.exists(out) or os.path.getmtime(out) < max(os.path.getmtime(s) for s in srcs):
        res = subprocess.run(["swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macos13.0", "-o", out, *srcs,
                              "-framework", "Cocoa", "-framework", "Carbon", "-framework", "Speech", "-framework", "AVFoundation",
                              "-framework", "CoreAudio", "-framework", "AudioToolbox"], capture_output=True, text=True)
        assert res.returncode == 0, res.stderr[-2000:]
    return out


@pytest.mark.skipif(sys.platform != "darwin", reason="CoreAudio is macOS-only")
def test_list_mics_reports_the_inputs_and_exits_without_connecting():
    helper = _build_helper()
    res = subprocess.run([helper, "--list-mics", "--port", "1"], capture_output=True, text=True, timeout=30)
    assert res.returncode == 0
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    assert len(lines) >= 1, "no input devices listed"
    assert sum(1 for l in lines if l.startswith("*")) == 1, "exactly one input must be flagged as the default"
    assert all("\t" in l for l in lines)                       # "<uid>\t<name>"
    assert "connecting to Filo" not in res.stderr             # it never talks to a running Filo
