#!/usr/bin/env python3
"""Synthesizes the speech fixtures used by the audio tests: game questions spoken by the repo's own
Kokoro voice (tts/), resampled to 16 kHz mono, with the exact speech interval recorded.

    tts/venv/bin/python scripts/gen_speech_fixtures.py [--out logs/fixtures/speech] [--force]

Output: <out>/base/NN_game.wav and <out>/manifest.json:
    [{"id", "game", "text", "keywords", "voice", "file", "duration", "speech_start", "speech_end"}]
Each base file is 50 ms padding + the utterance + 50 ms padding; `speech_start/end` are in seconds.
The variants (leading silence, late press, mid-sentence pause, noise) are built from these by
tests/speech_lib.py so the ground truth stays exact.
"""
import argparse
import json
import os
import sys
import wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PHRASES = [
    # (game, text, keywords that must survive recognition)
    ("Terraria", "How do I beat the Eye of Cthulhu in Terraria", ["eye", "cthulhu", "terraria"]),
    ("Terraria", "Where do I find the Guide voodoo doll", ["voodoo", "doll"]),
    ("Terraria", "What does the Wall of Flesh drop", ["wall", "flesh", "drop"]),
    ("Terraria", "How do I summon Skeletron", ["summon", "skeletron"]),
    ("Terraria", "What is the best pickaxe before hardmode", ["pickaxe", "hardmode"]),
    ("Terraria", "How do I get the Terra Blade", ["terra", "blade"]),
    ("Sekiro", "How do I beat Lady Butterfly in Sekiro", ["butterfly", "sekiro"]),
    ("Sekiro", "Where do I find the Shinobi Firecracker", ["shinobi", "firecracker"]),
    ("Sekiro", "How do I defeat the Guardian Ape", ["guardian", "ape"]),
    ("Sekiro", "What is Genichiro Ashina weak to", ["genichiro", "weak"]),
    ("Sekiro", "How do I get the Mortal Blade", ["mortal", "blade"]),
    ("Sekiro", "Who is Isshin the Sword Saint", ["isshin", "sword", "saint"]),
    ("Dark Souls", "Where do I find the Lordvessel in Dark Souls", ["lordvessel", "dark", "souls"]),
    ("Dark Souls", "How do I beat Ornstein and Smough", ["ornstein", "smough"]),
    ("Dark Souls", "How do I reach Sen's Fortress", ["reach", "fortress"]),
    ("Dark Souls", "Where is the Firelink Shrine bonfire", ["firelink", "shrine", "bonfire"]),
    ("Dark Souls", "How do I kill Gwyn Lord of Cinder", ["gwyn", "cinder"]),
    ("Dark Souls", "Where do I upgrade the Estus Flask", ["estus", "flask"]),
    ("Crimson Desert", "Who is Kliff in Crimson Desert", ["kliff", "crimson", "desert"]),
    ("Crimson Desert", "What is Oongka's role in Crimson Desert", ["oongka", "role"]),
    ("Crimson Desert", "How do I recruit Damiane", ["recruit", "damiane"]),
    ("Crimson Desert", "Where do I find the Greymane camp", ["greymane", "camp"]),
    ("Crimson Desert", "How do I beat the Reed Devil boss", ["reed", "devil", "boss"]),
    ("Crimson Desert", "What weapons can Kliff use", ["weapons", "kliff"]),
]
VOICES = ["af_heart", "am_michael", "bf_emma", "am_adam"]
RATE = 16_000


def resample_to_16k(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == RATE:
        return x.astype(np.float32)
    # simple anti-alias (moving average sized to the ratio) + linear interpolation; plenty for speech fixtures
    k = max(1, int(round(sr / RATE)))
    if k > 1:
        kernel = np.ones(k, dtype=np.float32) / k
        x = np.convolve(x, kernel, mode="same")
    t_out = np.arange(0, len(x) / sr, 1.0 / RATE)
    return np.interp(t_out, np.arange(len(x)) / sr, x).astype(np.float32)


def speech_interval(x: np.ndarray) -> tuple:
    """(start, end) in seconds of the audible part: frames whose level is within ~26 dB of the peak frame."""
    n = int(0.010 * RATE)
    frames = x[: len(x) // n * n].reshape(-1, n)
    level = np.sqrt((frames ** 2).mean(axis=1))
    thr = max(level.max() * 0.05, 1e-4)
    active = np.where(level > thr)[0]
    return active[0] * 0.010, (active[-1] + 1) * 0.010


def write_wav(path: str, x: np.ndarray) -> None:
    pcm = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "logs", "fixtures", "speech"))
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    manifest_path = os.path.join(args.out, "manifest.json")
    if os.path.exists(manifest_path) and not args.force:
        print("fixtures already exist:", manifest_path)
        return 0
    from kokoro_onnx import Kokoro  # only importable inside tts/venv

    os.makedirs(os.path.join(args.out, "base"), exist_ok=True)
    kokoro = Kokoro(os.path.join(ROOT, "tts", "models", "kokoro-v1.0.onnx"), os.path.join(ROOT, "tts", "models", "voices-v1.0.bin"))
    manifest = []
    for i, (game, text, keywords) in enumerate(PHRASES):
        voice = VOICES[i % len(VOICES)]
        samples, sr = kokoro.create(text, voice=voice, speed=1.0, lang="en-us")
        x = resample_to_16k(np.asarray(samples, dtype=np.float32), sr)
        x = x / max(1e-6, float(np.abs(x).max())) * 0.5          # a normal speaking level
        s0, s1 = speech_interval(x)
        pad = int(0.050 * RATE)
        a, b = max(0, int(s0 * RATE) - pad), min(len(x), int(s1 * RATE) + pad)
        clip = x[a:b]
        start = (int(s0 * RATE) - a) / RATE
        end = start + (s1 - s0)
        rel = "base/%02d_%s.wav" % (i, game.lower().replace(" ", "_"))
        write_wav(os.path.join(args.out, rel), clip)
        manifest.append({"id": i, "game": game, "text": text, "keywords": keywords, "voice": voice, "file": rel,
                         "duration": len(clip) / RATE, "speech_start": round(start, 3), "speech_end": round(end, 3)})
        print("%02d %-14s %-4s %.2fs speech %.2f-%.2f  %s" % (i, game, voice[:4], len(clip) / RATE, start, end, text))
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)
    print("wrote", manifest_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
