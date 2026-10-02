"""The real Swift helper against a raw TCP peer: the bridge protocol as the app uses it. No microphone is opened
(--no-speech), no speech permission is needed, and its log goes to a temp file."""
import json
import os
import socket
import subprocess
import sys
import time

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from test_helper_mics import _build_helper  # noqa: E402


class Peer:
    def __init__(self):
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.conn = None
        self.buf = b""

    def accept(self, timeout=15):
        self.server.settimeout(timeout)
        self.conn, _ = self.server.accept()
        self.conn.settimeout(6)

    def send(self, obj):
        self.conn.sendall((json.dumps(obj) + "\n").encode())

    def read_until(self, event, timeout=8):
        """Reads lines until one with this event arrives; returns it (and everything seen before it)."""
        seen = []
        end = time.time() + timeout
        while time.time() < end:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                msg = json.loads(line)
                seen.append(msg)
                if msg.get("event") == event:
                    return msg, seen
            try:
                chunk = self.conn.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                break
            self.buf += chunk
        raise AssertionError("no '%s' event; saw %s" % (event, seen))


@pytest.fixture()
def helper(tmp_path):
    if sys.platform != "darwin":
        pytest.skip("macOS only")
    binary = _build_helper()
    peer = Peer()
    env = dict(os.environ, FILO_HELPER_LOG=str(tmp_path / "helper.log"))
    proc = subprocess.Popen([binary, "--port", str(peer.port), "--no-speech", "--key", "f18", "--mods", "",
                             "--mute-key", "f17", "--mute-mods", "", "--panic-key", "f16", "--panic-mods", "",
                             "--parent-pid", str(os.getpid())], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        peer.accept()
        yield peer, proc
    finally:
        try:
            peer.send({"cmd": "quit"})
        except Exception:
            pass
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
        peer.server.close()


def test_ready_event_and_ping(helper):
    peer, _ = helper
    ready, _ = peer.read_until("ready")
    assert ready["hotkey_registered"] in (True, False) and "speech" in ready and ready["follow_up"] is False
    peer.send({"cmd": "ping"})
    peer.read_until("pong")


def test_set_mute_is_acknowledged_with_mute_state(helper):
    peer, _ = helper
    peer.read_until("ready")
    peer.send({"cmd": "set_mute", "muted": True})
    msg, _ = peer.read_until("mute_state")
    assert msg["muted"] is True and msg["source"] == "command"
    peer.send({"cmd": "set_mute", "muted": False})
    msg, _ = peer.read_until("mute_state")
    assert msg["muted"] is False


def test_list_mics_returns_the_devices(helper):
    peer, _ = helper
    peer.read_until("ready")
    peer.send({"cmd": "list_mics"})
    msg, _ = peer.read_until("mics")
    assert len(msg["devices"]) >= 1 and all({"uid", "name", "default"} <= set(d) for d in msg["devices"])
    assert sum(1 for d in msg["devices"] if d["default"]) == 1


def test_a_muted_hold_reports_instead_of_listening(helper):
    peer, _ = helper
    peer.read_until("ready")
    peer.send({"cmd": "set_mute", "muted": True})
    peer.read_until("mute_state")
    peer.send({"cmd": "simulate_hotkey", "pressed": True})
    time.sleep(0.5)                                                   # a real hold, not a tap
    peer.send({"cmd": "simulate_hotkey", "pressed": False})
    msg, seen = peer.read_until("error")
    assert msg["code"] == "muted"
    assert not any(m.get("event") == "hotkey_down" for m in seen), "a muted press must not start a capture"


def test_a_muted_tap_still_reaches_the_app_for_typing(helper):
    peer, _ = helper
    peer.read_until("ready")
    peer.send({"cmd": "set_mute", "muted": True})
    peer.read_until("mute_state")
    peer.send({"cmd": "simulate_hotkey", "pressed": True})
    peer.send({"cmd": "simulate_hotkey", "pressed": False})
    peer.read_until("tap")


def test_focus_vocab_and_unknown_commands_do_not_break_it(helper):
    peer, proc = helper
    peer.read_until("ready")
    for cmd in ({"cmd": "focus_save"}, {"cmd": "focus_restore"}, {"cmd": "set_vocab", "words": ["Kliff", "Oongka"]}, {"cmd": "no_such_command"}, {"cmd": "set_mic", "uid": "definitely-not-a-device"}):
        peer.send(cmd)
    msg, _ = peer.read_until("error")                                  # only the unknown microphone complains
    assert msg["code"] == "no_input_device"
    peer.send({"cmd": "ping"})
    peer.read_until("pong")                                            # and it is still alive
    assert proc.poll() is None
