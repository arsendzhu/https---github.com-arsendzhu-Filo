"""Speech capture tests: pre-roll, hangover, push-to-talk tail, "speech is never clipped".

The Swift segmenter (helper/Sources/AudioSegmenter.swift, the code the helper runs) is compiled into a
CLI and driven with (a) synthetic signals and (b) synthesized game questions with exact speech times,
in ten scenarios (late key press, early release, pauses in the sentence, noise at 10-20 dB SNR ...).
The old capture path is modelled for comparison (see speech_lib.legacy_capture).
"""
import json
import os
import subprocess

import numpy as np
import pytest

import speech_lib as sl

PHRASE_IDS = [0, 3, 6, 8, 12, 13, 18, 19, 21, 23]          # ten phrases, all four games, four voices


@pytest.fixture(scope="module")
def manifest():
    return sl.load_manifest()


@pytest.fixture(scope="module")
def work(tmp_path_factory):
    return str(tmp_path_factory.mktemp("speech"))


def _items(manifest):
    return [m for m in manifest if m["id"] in PHRASE_IDS]


def test_segmenter_selftest_on_synthetic_signals():
    """The Swift-side unit tests: ring buffer wrap-around, onset, hangover, pauses, noise, clicks, PTT, 48 kHz."""
    res = subprocess.run([sl.build_cli(), "selftest"], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout[-3000:]
    assert "all segmenter checks passed" in res.stdout


def test_vad_preroll_and_hangover(manifest, work):
    """Every VAD-mode utterance keeps >= ~400 ms before the first syllable and >= ~700 ms after the last;
    a 0.6 s pause inside the sentence does not split it; noise does not shorten the margins."""
    for name in ["vad_clean", "vad_long_lead", "vad_mid_pause_0.6", "vad_noise_20db", "vad_noise_10db"]:
        sc = sl.BY_NAME[name]
        for item in _items(manifest):
            st = sl.make_stream(item, sc)
            utts = sl.new_capture(st, sc, work, "%s_%d" % (name, item["id"]))
            tag = "%s/%s" % (name, item["text"])
            assert len(utts) == 1, "%s: expected one utterance, got %d" % (tag, len(utts))
            u = utts[0]
            assert u["preroll_ms"] >= 400, "%s: only %.0f ms of pre-roll" % (tag, u["preroll_ms"])
            assert u["tail_ms"] >= 700, "%s: only %.0f ms of hangover" % (tag, u["tail_ms"])
            cov = sl.coverage(u["start"], u["end"], st["s0"], st["s1"])
            assert cov >= 0.99, "%s: speech coverage %.3f" % (tag, cov)
    # the pause is inside the utterance: the detected speech span includes both halves
    sc = sl.BY_NAME["vad_mid_pause_0.6"]
    st = sl.make_stream(_items(manifest)[0], sc)
    u = sl.new_capture(st, sc, work, "pause_span")[0]
    assert u["speech_end"] - u["speech_start"] >= (st["s1"] - st["s0"]) - 0.15


def test_hangover_ends_utterance_after_long_silence(manifest, work):
    """Two questions 2 s apart are two utterances (the hangover, ~0.8 s, ends the first)."""
    item = _items(manifest)[0]
    a = sl.make_stream(item, sl.BY_NAME["vad_clean"])
    b = sl.make_stream(_items(manifest)[1], sl.BY_NAME["vad_clean"])
    st = dict(a)
    st["x"] = np.concatenate([a["x"], b["x"]])
    utts = sl.new_capture(st, sl.BY_NAME["vad_clean"], work, "two_questions")
    assert len(utts) == 2, utts


def test_speech_not_clipped(manifest, work):
    """Across all ten scenarios the new capture keeps >= 99 % of the speech; the old push-to-talk path
    (cold start on the key press, hard stop on release) does not, which is the reported bug."""
    rows = []
    worst_new = 1.0
    for sc in sl.SCENARIOS:
        for item in _items(manifest):
            st = sl.make_stream(item, sc)
            utts = sl.new_capture(st, sc, work, "%s_%d" % (sc.name, item["id"]))
            assert utts, "%s/%s: no utterance was captured at all" % (sc.name, item["text"])
            # all captured utterances together must cover the speech
            best = max(sl.coverage(u["start"], u["end"], st["s0"], st["s1"]) for u in utts)
            worst_new = min(worst_new, best)
            assert best >= 0.99, "%s / %s: new capture covers only %.3f of the speech" % (sc.name, item["text"], best)
            old = sl.legacy_capture(st, sc)
            if old is not None:
                cov_old = sl.coverage(old[0], old[1], st["s0"], st["s1"])
                assert best >= cov_old - 1e-9, "%s: the new capture is worse than the old one" % sc.name
                rows.append((sc.name, best, cov_old))
    old_late = [c for n, _, c in rows if n in ("ptt_late_press", "ptt_late_and_early", "ptt_early_release")]
    assert old_late and np.mean(old_late) < 0.93, "the scenarios do not reproduce clipping in the old path (mean %.3f)" % np.mean(old_late)
    print("worst new-capture coverage: %.4f; mean old-path coverage in the clipping scenarios: %.3f" % (worst_new, np.mean(old_late)))


def test_ptt_tail_and_preroll_margins(manifest, work):
    sc = sl.BY_NAME["ptt_late_and_early"]
    for item in _items(manifest)[:4]:
        st = sl.make_stream(item, sc)
        u = sl.new_capture(st, sc, work, "ptt_margins_%d" % item["id"])[0]
        assert u["reason"] == "ptt"
        assert u["start"] <= st["press"] - 0.40, "pre-roll before the press is missing: starts at %.2f, press at %.2f" % (u["start"], st["press"])
        assert u["end"] >= st["release"] + 0.28, "the 300 ms tail after the release is missing: ends %.2f, release %.2f" % (u["end"], st["release"])


def test_keywords_recovered_by_reference_recognizer():
    """End to end with a real recogniser (faster-whisper base.en, offline; the dev-only venv in stt/venv) and
    the per-game hotwords the helper also sends to the recogniser: what the *new* capture delivers loses
    almost nothing against perfectly captured speech (the recogniser's own ceiling), and is far more accurate
    than what the old push-to-talk path delivered. Skipped only when stt/venv is not installed."""
    py = os.path.join(sl.ROOT, "stt", "venv", "bin", "python")
    if not os.path.exists(py):
        pytest.skip("stt/venv not installed (python3 -m venv stt/venv && stt/venv/bin/pip install faster-whisper numpy jiwer)")
    out = os.path.join(sl.BUILD, "stt_quick.json")
    res = subprocess.run([py, os.path.join(sl.ROOT, "scripts", "eval_stt.py"), "--models", "base.en", "--hotwords", "--scenarios",
                          "ptt_late_and_early,ptt_late_press,ptt_early_release,vad_noise_10db", "--json", out, "--quiet"],
                         capture_output=True, text=True)
    assert res.returncode == 0, res.stderr[-2000:] + res.stdout[-2000:]
    data = json.load(open(out))["base.en"]
    ceiling = data["ideal_uncut"]
    for sc in ("ptt_late_and_early", "ptt_late_press", "ptt_early_release", "vad_noise_10db"):
        new = data[sc]["new"]
        assert new["keyword_recall"] >= ceiling["keyword_recall"] - 0.10, "%s: recall %.2f vs %.2f on uncut speech" % (sc, new["keyword_recall"], ceiling["keyword_recall"])
        assert new["wer"] <= ceiling["wer"] + 0.05, "%s: WER %.3f vs %.3f on uncut speech" % (sc, new["wer"], ceiling["wer"])
    for sc in ("ptt_late_and_early", "ptt_late_press"):
        assert data[sc]["new"]["wer"] <= data[sc]["legacy"]["wer"] - 0.05, "%s: WER new %.3f vs legacy %.3f" % (sc, data[sc]["new"]["wer"], data[sc]["legacy"]["wer"])
    assert data["ptt_early_release"]["new"]["wer"] <= data["ptt_early_release"]["legacy"]["wer"] + 1e-9
