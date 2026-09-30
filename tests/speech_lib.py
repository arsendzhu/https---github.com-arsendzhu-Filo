"""Shared helpers for the speech-capture tests and the STT evaluation (numpy only).

The ground truth comes from scripts/gen_speech_fixtures.py (a synthesized game question and the exact
seconds at which speech starts and ends). A *scenario* turns it into a microphone stream (leading
silence, a late key press, a pause inside the sentence, background noise ...) and a *capture policy*
decides which part of that stream reaches the recogniser:

  legacy  what the helper used to do: the audio engine + recogniser are cold-started on the key press
          (COLD_START_MS of speech lost) and audio stops at the very instant of the release
  new     helper/Sources/AudioSegmenter.swift (compiled to a CLI): pre-roll ring buffer, hangover,
          300 ms push-to-talk tail. Run exactly as the helper feeds it, in 2048-sample chunks.
"""
from __future__ import annotations

import json
import os
import subprocess
import wave
from dataclasses import dataclass
from typing import Optional

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "logs", "fixtures", "speech")
BUILD = os.path.join(ROOT, "logs", "build")
RATE = 16_000
# Measured on the old path: engine.stop() when the wake listener yields, then Permissions.request (async),
# engine.prepare()/start() and the recogniser task set-up. 250 ms is a conservative figure (the
# sensitivity to it is reported by scripts/eval_stt.py --cold-start-sweep).
COLD_START_MS = 250


@dataclass(frozen=True)
class Scenario:
    name: str
    mode: str = "vad"                 # "vad" | "ptt"
    lead: float = 1.0                 # seconds of silence/noise before the phrase
    tail: float = 2.0                 # ... and after it
    pause_len: float = 0.0            # silence inserted in the middle of the phrase
    snr_db: Optional[float] = None    # background noise level relative to the speech, None = quiet room
    press: float = 0.0                # PTT: key down, seconds relative to the speech start (>0 = late)
    release: float = 0.0              # PTT: key up, seconds relative to the speech end (<0 = early)


SCENARIOS = [
    Scenario("vad_clean"),
    Scenario("vad_long_lead", lead=3.0),
    Scenario("vad_mid_pause_0.6", pause_len=0.6),
    Scenario("vad_noise_20db", snr_db=20),
    Scenario("vad_noise_10db", snr_db=10),
    Scenario("ptt_press_before", mode="ptt", press=-0.20, release=0.05),
    Scenario("ptt_late_press", mode="ptt", press=0.15, release=0.05),
    Scenario("ptt_early_release", mode="ptt", press=-0.20, release=-0.10),
    Scenario("ptt_late_and_early", mode="ptt", press=0.15, release=-0.10),
    Scenario("ptt_late_and_early_noise_15db", mode="ptt", press=0.15, release=-0.10, snr_db=15),
]
BY_NAME = {s.name: s for s in SCENARIOS}


# ------------------------------------------------------------------------------------------ files

def ensure_fixtures() -> str:
    manifest = os.path.join(FIXTURES, "manifest.json")
    if not os.path.exists(manifest):
        py = os.path.join(ROOT, "tts", "venv", "bin", "python")
        if not os.path.exists(py):
            raise RuntimeError("no fixtures and no tts/venv (run scripts/setup_voice.sh, or scripts/gen_speech_fixtures.py)")
        subprocess.run([py, os.path.join(ROOT, "scripts", "gen_speech_fixtures.py")], check=True, capture_output=True)
    return manifest


def load_manifest() -> list:
    with open(ensure_fixtures()) as f:
        return json.load(f)


def read_wav(path: str) -> np.ndarray:
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path: str, x: np.ndarray, rate: int = RATE) -> None:
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


CLI_SOURCES = ["AudioSegmenter.swift", "AudioTapCore.swift", "CaptureAnalyzer.swift", "Log.swift"]


def build_cli() -> str:
    """Compiles the segmenter test harness with the helper sources it exercises (cached until one changes)."""
    os.makedirs(BUILD, exist_ok=True)
    out = os.path.join(BUILD, "segmenter_cli")
    srcs = [os.path.join(ROOT, "helper", "Sources", f) for f in CLI_SOURCES] + [os.path.join(ROOT, "helper", "Tests", "segmenter_cli.swift")]
    if not os.path.exists(out) or os.path.getmtime(out) < max(os.path.getmtime(s) for s in srcs):
        res = subprocess.run(["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-o", out, *srcs, "-framework", "AVFoundation"],
                             capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError("segmenter CLI failed to compile:\n" + res.stderr[-3000:])
    return out


# --------------------------------------------------------------------------------------- streams

def make_stream(item: dict, sc: Scenario, seed: int = 0) -> dict:
    """The microphone stream of one scenario: {x, s0, s1, press, release} (times in seconds)."""
    base = read_wav(os.path.join(FIXTURES, item["file"]))
    a = int(item["speech_start"] * RATE)
    b = int(item["speech_end"] * RATE)
    speech = base[a:b]
    if sc.pause_len > 0:                                   # a pause between two words, roughly mid-phrase
        cut = len(speech) // 2
        speech = np.concatenate([speech[:cut], np.zeros(int(sc.pause_len * RATE), np.float32), speech[cut:]])
    x = np.concatenate([np.zeros(int(sc.lead * RATE), np.float32), speech, np.zeros(int(sc.tail * RATE), np.float32)])
    s0 = sc.lead
    s1 = sc.lead + len(speech) / RATE
    if sc.snr_db is not None:
        rng = np.random.default_rng(seed + item["id"])
        noise = rng.standard_normal(len(x)).astype(np.float32)
        noise = np.convolve(noise, np.ones(4, np.float32) / 4, mode="same")            # a bit of low-pass: room-like
        speech_rms = float(np.sqrt(np.mean(speech ** 2)))
        noise *= speech_rms / (10 ** (sc.snr_db / 20)) / max(1e-9, float(np.sqrt(np.mean(noise ** 2))))
        x = x + noise
    else:
        rng = np.random.default_rng(seed + item["id"])
        x = x + (rng.standard_normal(len(x)) * 0.001).astype(np.float32)               # a real mic is never digitally silent
    return {"x": x.astype(np.float32), "s0": s0, "s1": s1, "press": s0 + sc.press, "release": s1 + sc.release}


# -------------------------------------------------------------------------------- capture policies

def legacy_capture(stream: dict, sc: Scenario, cold_start_ms: float = COLD_START_MS) -> Optional[tuple]:
    """(start, end) seconds the old push-to-talk path delivered. VAD scenarios did not use it."""
    if sc.mode != "ptt":
        return None
    return stream["press"] + cold_start_ms / 1000.0, stream["release"]


def new_capture(stream: dict, sc: Scenario, workdir: str, name: str) -> list:
    """Runs the stream through the Swift segmenter. Returns [{start, end, speech_start, speech_end,
    preroll_ms, tail_ms, reason, samples}] (samples = the audio that would reach the recogniser)."""
    cli = build_cli()
    os.makedirs(workdir, exist_ok=True)
    wav = os.path.join(workdir, name + ".wav")
    write_wav(wav, stream["x"])
    outdir = os.path.join(workdir, name + "_utts")
    cmd = [cli, "segment", wav, "--out-dir", outdir]
    if sc.mode == "ptt":
        cmd += ["--mode", "ptt", "--press", "%.4f" % stream["press"], "--release", "%.4f" % stream["release"]]
    res = subprocess.run(cmd, check=True, capture_output=True, text=True)
    utts = []
    for line in res.stdout.splitlines():
        if line.startswith("{"):
            u = json.loads(line)
            u["samples"] = read_wav(os.path.join(outdir, "utt_%d.wav" % u["index"]))
            utts.append(u)
    return utts


def coverage(start: float, end: float, s0: float, s1: float) -> float:
    """Fraction of the speech interval [s0, s1] that lies inside the captured [start, end]."""
    return max(0.0, min(end, s1) - max(start, s0)) / (s1 - s0)


# ---------------------------------------------------------------------------------------- scoring

def normalize(text: str) -> str:
    keep = []
    for ch in text.lower():
        keep.append(ch if (ch.isalnum() or ch in " '") else " ")
    return " ".join("".join(keep).replace("'s", "s").replace("'", "").split())


def keyword_recall(text: str, keywords: list) -> float:
    words = set(normalize(text).split())
    joined = normalize(text).replace(" ", "")
    hit = sum(1 for k in keywords if k in words or k in joined)
    return hit / len(keywords)
