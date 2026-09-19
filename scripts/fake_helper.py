#!/usr/bin/env python3
"""Stand-in for the native helper used by scripts/test.sh: connects to Filo's
bridge port and plays a scripted push-to-talk session (no mic, no hotkey).

Usage: fake_helper.py --port N [--question TEXT] [--delay S] [--tap-after S] [--tap-again S] [--tap-first]
--tap-after: seconds after the final transcript to tap (hushes the answer if still speaking)
--tap-again: seconds after that first tap to tap once more (dismisses when idle)
Unknown arguments (the ones Filo passes to the real helper) are ignored."""
import argparse
import json
import socket
import sys
import threading
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=47821)
ap.add_argument("--question", default="I'm stuck on the Guardian Ape, what am I missing?")
ap.add_argument("--delay", type=float, default=1.5)
ap.add_argument("--tap-after", type=float, default=0.0)
ap.add_argument("--tap-again", type=float, default=0.0)
ap.add_argument("--tap-first", action="store_true")
ap.add_argument("--wake", action="store_true", help="use the wake word instead of the hotkey")
ap.add_argument("--followup", default="", help="answer Filo's first 'anything else?' with this question, then say bye")
ap.add_argument("--no-bye", action="store_true", help="let open listening time out instead of saying bye")
args, _unknown = ap.parse_known_args()

sock = None
for _ in range(40):
    try:
        sock = socket.create_connection(("127.0.0.1", args.port), timeout=2)
        break
    except OSError:
        time.sleep(0.25)
if sock is None:
    sys.stderr.write("fake_helper: could not connect\n")
    sys.exit(1)
sock.settimeout(None)
lock = threading.Lock()


def send(obj):
    with lock:
        sock.sendall((json.dumps(obj) + "\n").encode())


followups_sent = [0]


def on_listen_open(cmd):
    """Filo asked 'anything else?': answer once with --followup, then say bye (or time out)."""
    def run():
        time.sleep(1.0)
        if args.followup and followups_sent[0] == 0:
            followups_sent[0] += 1
            words = args.followup.split()
            partial = ""
            for w in words:
                partial = (partial + " " + w).strip()
                send({"event": "partial", "text": partial})
                time.sleep(0.1)
            time.sleep(0.8)
            send({"event": "final", "text": args.followup})
        elif args.no_bye:
            send({"event": "listen_timeout", "reason": "silence"})
        else:
            send({"event": "bye"})
    threading.Thread(target=run, daemon=True).start()


def reader():
    buf = b""
    while True:
        try:
            data = sock.recv(4096)
        except OSError:
            break
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                cmd = json.loads(line.decode())
            except ValueError:
                continue
            sys.stderr.write("fake_helper <- %s\n" % json.dumps(cmd))
            sys.stderr.flush()
            if cmd.get("cmd") == "quit":
                sys.exit(0)
            if cmd.get("cmd") == "ping":
                send({"event": "pong"})
            if cmd.get("cmd") == "list_apps":
                send({"event": "apps", "apps": [{"name": "Finder", "bundle_id": "com.apple.finder"}]})
            if cmd.get("cmd") == "listen_open":
                on_listen_open(cmd)
    sys.exit(0)


threading.Thread(target=reader, daemon=True).start()
send({"event": "ready", "hotkey": "fake", "hotkey_registered": True, "speech": {"enabled": False}, "pid": 0})
send({"event": "apps", "apps": [{"name": "Finder", "bundle_id": "com.apple.finder"}]})
time.sleep(args.delay)

if args.tap_first:
    send({"event": "tap", "duration_ms": 120})
    time.sleep(2.5)
    send({"event": "tap", "duration_ms": 120})   # closes the typed panel again
    time.sleep(1.0)

if args.wake:
    send({"event": "wake_word", "phrase": "hey filo"})
else:
    send({"event": "hotkey_down"})
words = args.question.split()
partial = ""
for w in words:
    partial = (partial + " " + w).strip()
    send({"event": "level", "value": 0.4 + 0.5 * (len(w) % 3) / 2.0})
    send({"event": "partial", "text": partial})
    time.sleep(0.12)
time.sleep(0.4)
if not args.wake:
    send({"event": "hotkey_up", "duration_ms": int(1000 * (0.4 + 0.12 * len(words)))})
time.sleep(0.5 if not args.wake else 1.5)
send({"event": "final", "text": args.question})

if args.tap_after > 0:
    time.sleep(args.tap_after)
    send({"event": "tap", "duration_ms": 100})
    if args.tap_again > 0:
        time.sleep(args.tap_again)
        send({"event": "tap", "duration_ms": 100})

while True:
    time.sleep(1)
