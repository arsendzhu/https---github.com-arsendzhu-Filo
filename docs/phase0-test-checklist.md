# Phase 0 demo — test checklist

Do these on the Mac, in order. Every step lists what you should see. Nothing else starts until
this passes.

## 0. Setup (once)

```
scripts/build_helper.sh            # builds helper/build/Filo Helper.app (needs Xcode CLT)
scripts/build_native.sh            # builds the full-screen overlay extension
cp .env.example .env               # add NVIDIA_API_KEY (or ANTHROPIC_API_KEY)
scripts/test.sh                    # unit tests + offline end-to-end + showcase captures
```

Expected: `304 passed, 0 failed`, only `ok:` lines (no `FAIL:`), `captured 24 review frames`, `ALL TESTS PASSED`.
Optional but recommended: `scripts/setup_voice.sh` (installs the free Kokoro voice, ~340 MB).

## 1. Launch

`scripts/run.sh`

- [ ] Terminal shows `LLM: NVIDIA NIM (nvidia/nemotron-3-super-120b-a12b)` (or Claude), then
      `Helper connected` and `Helper ready: {... "hotkey_registered":true ... "wake_word":"hey filo"}`.
- [ ] First launch: macOS asks for **Speech Recognition** then **Microphone** for "Filo Helper". Allow both.
- [ ] A cube spins in at the bottom-right, scaling up with a small bounce, eyes opening at the end
      of the spin; a bubble says hi; a faint hint sits under the cube. It bobs and blinks, then
      spins out after ~8 s.

## 2. Wake word, follow-ups, bye

Say: **"Hey Filo, I'm stuck on the Guardian Ape, what am I missing?"** (pause when done)

- [ ] On "hey filo" the cube wakes and levitates; the bubble shows "● Listening" and the live
      transcript; the cube leans in and pulses with your voice, eyes wide.
- [ ] ~1.5 s after you stop: a quick nod, then either the slow spin or a head-tilt "hmm", with
      "Thinking…" in the bubble.
- [ ] Then it nudges forward, turns toward the bubble, speaks the answer (Kokoro voice if
      installed, otherwise the system voice) while its mouth moves with the sound and the text
      reveals; footer `◆ notes: Guardian Ape`.
- [ ] Right after: a little reaction (happy face, wink, hop or nod) and it asks "Anything else?"
      (varied), then the bubble shows "● Listening" with "say “bye filo” when you're done".
- [ ] Just answer, no wake word: "what about its second phase?" → it answers in context.
- [ ] Stay silent for ~30 s → it stops listening but stays on screen, idle and fidgeting
      (glances, stretches, tilts). "Hey filo" wakes it again.
- [ ] Say "bye filo" → it says bye with a little hop and spins out.
- [ ] Ask something outside the notes, e.g. "who is Ganon in Zelda?" → terminal shows
      `asking Wikipedia` and `Wikipedia: 2 page(s)`; the footer shows `web: Ganon (en.wikipedia.org)`.
- [ ] Ask "who are you?" → it describes itself as a general game companion/wiki guide, not a
      Sekiro-only bot (it should still mention it's currently loaded with Sekiro notes).

## 2b. Bubble controls, and the mascot never getting stuck on one look

- [ ] A small speaker icon sits in the bubble's bottom-left corner, in every bubble mode. Click
      it: Filo goes silent instantly (if it was mid-answer, the text stays fully visible and it
      moves on without auto-reprompting); the icon switches to a slashed speaker. Click again to
      restore sound. This should work even though clicking elsewhere on the overlay still passes
      through to whatever's behind it.
- [ ] After the *first* answer, a second small icon (a mic) appears next to the speaker icon.
      Click it: it becomes a small keyboard icon, and the *next* "anything else?" opens an empty
      text box instead of the microphone (type a follow-up, or "bye", to test it). Click it again
      while that box is open to switch back to voice immediately. Say "bye filo" or dismiss and
      wake again — the icon should reset to the mic (voice mode) for the new conversation.
- [ ] Have a longer conversation — 6-8 questions in a row. The idle face between turns should
      visibly vary (the classic look, a curious wide-eyed glance, a focused narrower look, an
      extra-cute big-eyed look, the happy "^ ^" look), never stuck on one, and the original
      both-eyes-open idle look should keep reappearing rather than disappearing for good.
- [ ] Specifically watch for the bug this session fixed: after a "wink" reaction (one eye closes
      briefly right after an answer), confirm the *next* time Filo talks or rests, **both eyes are
      fully open again** — it should never keep speaking or resting with one eye stuck shut, no
      matter how many turns follow.

## 3. Push-to-talk

Hold ⌥ Space and say "how do I deal with the chained ogre grabs", release.

- [ ] Same flow as above; `~/Library/Logs/Filo/helper.log` shows `hotkey down` / `hotkey up`.

## 4. Click-through and stacking

- [ ] With the cube visible, click on it and drag on the desktop behind it: the click goes to
      whatever is behind — the overlay never takes focus.
- [ ] Bring any windowed app (Safari, a video) to the front: the cube stays on top of it.
- [ ] Put Safari (or any app) in macOS full-screen mode and say "hey filo": the cube appears over
      the full-screen app too. Terminal shows `[filo_overlay] running as an accessory app` and
      `… now joins all Spaces`.

## 5. Typed question and dismiss

- [ ] Tap ⌥ Space (short press): the cube wakes and a text field appears. Type
      "who is lady butterfly and how do I reach her", Enter → same think/answer flow.
- [ ] Esc closes the field; tap ⌥ Space while the cube is awake (idle, listening or talking) → it
      spins out (opposite direction, eyes closing part-way, no bounce).
- [ ] Type `/glint` → the shine in each eye turns cyan and twinkles (the screen-reading cue
      preview); `/glint` again turns it off.

## 6. Failure modes (should never crash)

- [ ] Wrong key in .env → bubble "…rejected the API key", the cube shakes its head.
- [ ] No key → answers come "straight from my notes" with a source.
- [ ] Quit with Ctrl-C in the terminal (or type `/quit` in the box) → the helper exits too
      (`pgrep filo-helper` shows nothing). Filo has no Dock icon while it runs; that is expected.

## 7. Showcase (for recording)

`scripts/run.sh --showcase` tours: asleep → summon → idle → blink → listening → thinking →
answering → pleased → glint cue → error shake → dismiss. Add `--capture-dir ~/Desktop/filo-frames`
to save PNGs (the `*_review.png` copies are composited on a checkerboard).
