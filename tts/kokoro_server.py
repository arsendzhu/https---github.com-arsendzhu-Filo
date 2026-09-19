#!/usr/bin/env python3
"""Local neural text-to-speech for Filo (Kokoro-82M via kokoro-onnx, CPU, offline).

  GET  /health                      -> {"ok": true, "voice": "...", "sample_rate": 24000}
  POST /synthesize {"text","voice","speed"} -> audio/wav (16-bit PCM mono 24 kHz)

Started by the app when tts.provider is "auto" or "kokoro" and tts/venv exists.
"""
import argparse
import io
import json
import os
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=47823)
ap.add_argument("--model", default=os.path.join(ROOT, "tts", "models", "kokoro-v1.0.onnx"))
ap.add_argument("--voices", default=os.path.join(ROOT, "tts", "models", "voices-v1.0.bin"))
ap.add_argument("--voice", default="af_heart")
args = ap.parse_args()

try:
    from kokoro_onnx import Kokoro
except Exception as e:  # pragma: no cover
    sys.stderr.write("kokoro_server: kokoro-onnx not installed (%s)\n" % e)
    sys.exit(2)

t0 = time.time()
kokoro = Kokoro(args.model, args.voices)
sys.stderr.write("kokoro_server: model loaded in %.1fs, voice %s, port %d\n" % (time.time() - t0, args.voice, args.port))


def synthesize(text, voice, speed):
    samples, sr = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
    pcm = np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0)
    pcm16 = (pcm * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm16.tobytes())
    return buf.getvalue(), sr, len(pcm16) / float(sr)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/health"):
            return self._json(200, {"ok": True, "voice": args.voice, "sample_rate": 24000, "engine": "kokoro-onnx"})
        self._json(404, {"ok": False})

    def do_POST(self):
        if self.path != "/synthesize":
            return self._json(404, {"ok": False})
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._json(400, {"ok": False, "error": "bad json"})
        text = str(body.get("text", "")).strip()
        if not text:
            return self._json(400, {"ok": False, "error": "empty text"})
        voice = str(body.get("voice") or args.voice)
        speed = float(body.get("speed") or 1.0)
        t = time.time()
        try:
            wav, sr, seconds = synthesize(text, voice, speed)
        except Exception as e:
            sys.stderr.write("kokoro_server: synth failed: %s\n" % e)
            return self._json(500, {"ok": False, "error": str(e)})
        sys.stderr.write("kokoro_server: %d chars -> %.1fs audio in %.2fs\n" % (len(text), seconds, time.time() - t))
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(wav)))
        self.send_header("X-Audio-Seconds", "%.3f" % seconds)
        self.end_headers()
        self.wfile.write(wav)


# Threaded so a slow synthesis never blocks /health checks from the app.
ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
