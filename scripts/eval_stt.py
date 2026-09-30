#!/usr/bin/env python3
"""Measures how the capture policy and recogniser settings change transcription accuracy on the
synthesized game questions (tests/speech_lib.py scenarios).

    stt/venv/bin/python scripts/eval_stt.py [--models tiny.en,base.en,small.en] [--scenarios a,b]
        [--hotwords] [--cold-start-sweep] [--dump-hyps logs/stt_hyps.json] [--json out.json] [--quiet]

For each scenario the same microphone stream is captured two ways:
  legacy  the old push-to-talk path (cold start on the key press, hard stop on release)
  new     the Swift segmenter (pre-roll, hangover, 300 ms release tail)
and transcribed by faster-whisper (offline; the *reference* recogniser - the helper itself uses Apple's
on-device recogniser, which cannot be run from a script without a permission dialog). Reports word
error rate (WER) and key-word recall. `--hotwords` adds the per-game vocabulary (profiles/vocabulary.json).
"""
import argparse
import json
import os
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import speech_lib as sl  # noqa: E402

PHRASE_IDS = [0, 3, 6, 8, 12, 13, 18, 19, 21, 23]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", default="base.en")
    ap.add_argument("--scenarios", default="")
    ap.add_argument("--hotwords", action="store_true")
    ap.add_argument("--all-phrases", action="store_true", help="use all 24 phrases instead of 10")
    ap.add_argument("--beam", type=int, default=5)
    ap.add_argument("--vad-filter", action="store_true", help="faster-whisper's built-in VAD filter (permissive settings)")
    ap.add_argument("--cold-start-sweep", action="store_true")
    ap.add_argument("--dump-hyps", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    import jiwer
    from faster_whisper import WhisperModel

    manifest = sl.load_manifest()
    items = manifest if args.all_phrases else [m for m in manifest if m["id"] in PHRASE_IDS]
    scenarios = [sl.BY_NAME[n] for n in args.scenarios.split(",") if n] if args.scenarios else sl.SCENARIOS
    vocab = json.load(open(os.path.join(ROOT, "profiles", "vocabulary.json")))
    work = os.path.join(sl.BUILD, "eval")
    results, hyps = {}, []

    for model_name in args.models.split(","):
        model = WhisperModel(model_name, device="cpu", compute_type="int8", download_root=os.path.join(ROOT, "stt", "models"))

        def transcribe(x: np.ndarray, game: str) -> str:
            if len(x) < 1600:
                return ""
            kw = {"hotwords": ", ".join(vocab.get(game, []))} if args.hotwords else {}
            vad = {"vad_filter": True, "vad_parameters": {"threshold": 0.3, "min_silence_duration_ms": 1500, "speech_pad_ms": 600}} if args.vad_filter else {}
            segs, _ = model.transcribe(x, language="en", beam_size=args.beam, condition_on_previous_text=False, **kw, **vad)
            return " ".join(s.text.strip() for s in segs).strip()

        model_res = {}
        # the recogniser's own error rate on perfectly captured speech (nothing clipped)
        t0 = time.time()
        ideal_refs, ideal_hyps, ideal_recall = [], [], []
        for item in items:
            st = sl.make_stream(item, sl.BY_NAME["vad_clean"])
            h = transcribe(st["x"], item["game"])
            ideal_refs.append(sl.normalize(item["text"]))
            ideal_hyps.append(sl.normalize(h))
            ideal_recall.append(sl.keyword_recall(h, item["keywords"]))
        model_res["ideal_uncut"] = {"wer": jiwer.wer(ideal_refs, ideal_hyps), "keyword_recall": float(np.mean(ideal_recall))}

        for sc in scenarios:
            rows = {"new": ([], [], []), "legacy": ([], [], [])}
            for item in items:
                st = sl.make_stream(item, sc)
                ref = sl.normalize(item["text"])
                utts = sl.new_capture(st, sc, work, "%s_%d" % (sc.name, item["id"]))
                h_new = " ".join(transcribe(u["samples"], item["game"]) for u in utts)
                old = sl.legacy_capture(st, sc)
                if old is None:
                    h_old = h_new
                else:
                    a, b = max(0, int(old[0] * sl.RATE)), min(len(st["x"]), int(old[1] * sl.RATE))
                    h_old = transcribe(st["x"][a:b], item["game"])
                for key, h in (("new", h_new), ("legacy", h_old)):
                    rows[key][0].append(ref)
                    rows[key][1].append(sl.normalize(h))
                    rows[key][2].append(sl.keyword_recall(h, item["keywords"]))
                hyps.append({"model": model_name, "scenario": sc.name, "id": item["id"], "game": item["game"], "ref": item["text"],
                             "keywords": item["keywords"], "new": h_new, "legacy": h_old})
            model_res[sc.name] = {k: {"wer": jiwer.wer(v[0], v[1]), "keyword_recall": float(np.mean(v[2]))} for k, v in rows.items()}
        if args.cold_start_sweep:
            sweep = {}
            sc = sl.BY_NAME["ptt_press_before"]
            for cold in (0, 100, 250, 400):
                refs, hs = [], []
                for item in items:
                    st = sl.make_stream(item, sc)
                    old = sl.legacy_capture(st, sc, cold)
                    a, b = max(0, int(old[0] * sl.RATE)), min(len(st["x"]), int(old[1] * sl.RATE))
                    refs.append(sl.normalize(item["text"]))
                    hs.append(sl.normalize(transcribe(st["x"][a:b], item["game"])))
                sweep[str(cold)] = jiwer.wer(refs, hs)
            model_res["legacy_cold_start_sweep_wer"] = sweep
        results[model_name] = model_res
        if not args.quiet:
            print("\n== %s%s  (%d phrases, %.0fs)" % (model_name, " + hotwords" if args.hotwords else "", len(items), time.time() - t0))
            print("   recogniser on uncut speech: WER %.3f, keyword recall %.2f" % (model_res["ideal_uncut"]["wer"], model_res["ideal_uncut"]["keyword_recall"]))
            print("   %-32s %18s %18s" % ("scenario", "legacy WER / recall", "new WER / recall"))
            for sc in scenarios:
                r = model_res[sc.name]
                print("   %-32s %9.3f / %.2f %11.3f / %.2f" % (sc.name, r["legacy"]["wer"], r["legacy"]["keyword_recall"], r["new"]["wer"], r["new"]["keyword_recall"]))
            if args.cold_start_sweep:
                print("   legacy WER vs cold-start latency (ptt_press_before):", model_res["legacy_cold_start_sweep_wer"])

    if args.json:
        os.makedirs(os.path.dirname(args.json), exist_ok=True)
        json.dump(results, open(args.json, "w"), indent=1)
    if args.dump_hyps:
        os.makedirs(os.path.dirname(args.dump_hyps), exist_ok=True)
        json.dump(hyps, open(args.dump_hyps, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
