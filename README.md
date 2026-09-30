# Filo — game overlay companion, Phase 0 (Mac-native shell)

A small pixel-art cube that lives in the corner of your screen, wakes up when you say
**"hey filo"** or hold a key, listens to your question, looks it up in curated notes or the web,
asks an LLM (Claude or NVIDIA NIM), and answers out loud with a source. Filo is a general,
portable wiki-style companion — built to work with any game, not just one — that happens to ship
with a Sekiro profile as its Phase 0 demo content; ask it about anything else and it falls back to
Wikipedia or live web search. This is **Phase 0** of the plan in *Game Overlay Companion — Starter
Pack*: overlay window, mascot with all its animations, voice in and out, notes/web answer loop —
built and tested on macOS against no particular game. Screen reading, live games and Windows come
in later phases.

## Requirements

- macOS on Apple Silicon (built and tested on macOS 26).
- [Godot 4.7](https://godotengine.org) — `brew install --cask godot`.
- Xcode or the Command Line Tools (`xcode-select --install`) to compile the tiny native helper.
- An API key: `NVIDIA_API_KEY` (NVIDIA NIM, free tier) or `ANTHROPIC_API_KEY` (Claude).
  Without either, Filo still runs and answers from the notes only.

## Setup

```sh
cp .env.example .env && chmod 600 .env    # put your key(s) in .env
scripts/build_helper.sh                   # compiles helper/build/Filo Helper.app
scripts/build_native.sh                   # compiles the full-screen overlay extension
scripts/run.sh                            # launch the demo (builds both if missing)
```

`scripts/test.sh` runs the unit tests (386 checks, no network), two offline end-to-end passes (hotkey and wake word,
with a mock Claude API and a scripted helper) and a showcase capture of every animation.

## Using it

| action | what happens |
| --- | --- |
| say **"hey filo"**, then ask | the cube spins in, listens (live transcript in the bubble), thinks, then answers out loud with its source |
| **hold ⌥ Space** and talk | same, push-to-talk |
| after every answer | Filo asks "anything else?" and keeps listening — just answer, no wake word needed |
| say **"bye filo"** or **tap ⌥ Space** | Filo says bye and spins out (it never disappears on its own) |
| **tap ⌥ Space** while asleep | summon + a typed-question box (Enter asks, Esc closes) |
| `/glint`, `/sleep`, `/quit`, `/help` in the box | preview the screen-reading cue · dismiss · quit · help |

Filo remembers the last few turns, so "what about its second phase?" works as a follow-up.
If you say nothing for 30 s after "anything else?", it stops listening for follow-ups but stays
on screen; "hey filo" wakes it again.

The bubble has two small buttons in its bottom-left corner (they're clickable even though the
overlay itself is click-through everywhere else):

- **speaker icon** — mutes/unmutes Filo's voice instantly, any time. Answers still appear as text.
- **mic/keyboard icon** — appears after the first answer; switches how the *next* "anything else?"
  is followed up: voice (mic opens, bubble shows "Listening") or text (an empty box opens, type
  your follow-up). Click it mid-listening or mid-typing to switch immediately.

**First launch:** macOS asks for **Speech Recognition** and **Microphone** for "Filo Helper"
(the wake word listens all the time, on-device, and macOS shows its orange microphone dot
while it does). Allow both. If you'd rather not have an always-on microphone, set
`"wake_word": {"enabled": false}` in `config.json` and use the key.

The hotkey is global (works while a game is focused) and never needs the Accessibility
permission. Change it under `hotkey` in `config.json` (e.g. `{"key": "f8", "modifiers": []}`).
The overlay is click-through and never takes focus, except while the typed box is open.

## Research agent (NVIDIA NIM tool calling)

With an `NVIDIA_API_KEY`, questions the notes don't answer confidently go to a small research
agent: the model can call `wiki_search` / `wiki_page` (the game's Fandom wiki, else Wikipedia),
`web_search` (DuckDuckGo behind a swappable provider) and `fetch_page`, then answers in 1–3 spoken
sentences. At most 4 model round trips and 6 tool calls, then a forced final answer. Tool output is
untrusted data (wrapped, sanitized, size-capped; private/loopback addresses are blocked), and
reasoning text never reaches the bubble or the voice. If every model in the chain fails, Filo falls
back to Claude (when a key exists) and then to the plain Wikipedia/notes path.

**Model chain** — `research.models` in `config.json`, tried in order; a model that returns
404/410/429/5xx or times out is skipped for `breaker_seconds` (so a dead model costs one timeout).
Default: `deepseek-ai/deepseek-v4.1-flash` → `nvidia/nemotron-3-super-120b-a12b` → Claude.

```json
"research": { "models": [ "nvidia/nemotron-3-super-120b-a12b", "meta/llama-3.3-70b-instruct" ] }
```

Entries are a model id or `{"id": …, "extra_body_no_think": {…}}` (the request fields that switch
thinking off for that model). At startup Filo calls `GET /v1/models` once and warns about ids that
aren't listed. Per game wikis: `wiki` in a profile's `profile.json`, or `research.wikis` for
games without a profile. The log prints which model answered and per-request latency.

> **Model notes (checked live, 2026-09-29):** `deepseek-ai/deepseek-v4-flash` (and `-0731`) now
> return **410 end of life**. `deepseek-v4.1-flash` is listed but did not respond within 100 s on the
> free tier, so in practice `nemotron-3-super-120b-a12b` answers (tool call in ~1 s; a full
> researched answer typically 4–10 s, occasionally 20 s+ on the shared free tier; ~40 requests/min).
> Whether DeepSeek accepts `chat_template_kwargs.thinking=false` could not be verified; a 400/422
> makes Filo retry once without it.

**Tests** — `scripts/test.sh` covers the agent offline (mock NIM, scripted tool calls, injected
prompts, SSRF, caps, fallback chain, end-to-end). Live, needs `NVIDIA_API_KEY`, otherwise prints
SKIPPED:

```sh
scripts/research_live.sh                                       # models listed + tool call returned
scripts/research_live.sh --bench                               # latency table, 6 sample questions
scripts/research_live.sh --bench --models nvidia/nemotron-3-super-120b-a12b
```

## Test it

Follow [docs/phase0-test-checklist.md](docs/phase0-test-checklist.md) — every step says what you
should see. `scripts/run.sh --showcase` tours every animation state for recording.

## Configuration

Keys go in `.env` (`ANTHROPIC_API_KEY`, `NVIDIA_API_KEY`, optional `FILO_PROVIDER`,
`FILO_MODEL`, `FILO_NIM_MODEL`); everything else in `config.json`:

| key | default | meaning |
| --- | --- | --- |
| `llm.provider` | `auto` | `auto` = Claude if it has a key, else NVIDIA NIM, else notes-only; or force `anthropic` / `nim` |
| `model`, `effort` | `claude-opus-5`, `low` | Claude model and reasoning effort (skipped for Haiku) |
| `nim.model`, `nim.reasoning` | `nvidia/nemotron-3-super-120b-a12b`, `false` | NIM model; reasoning off keeps spoken answers ~3 s |
| `research.*` | see above | NIM tool-calling agent: `models`, `thinking`, `max_rounds`, `max_tool_calls`, `attempt_timeout`, `tool_timeout`, `cache_ttl`, `breaker_seconds`, `claude_fallback`, `search_provider`, `wikis` |
| `refusal_fallbacks` | true | Claude only: server-side fallback if the safety classifier declines a request |
| `web_search.enabled` / `max_uses` / `confidence_threshold` | true / 2 / 0.45 | live web fallback when the notes don't cover the question |
| `web_search.provider` | `auto` | `auto` = Claude's web search with Claude, free **Wikipedia** summaries otherwise (NIM); or `anthropic` / `wikipedia` / `off` |
| `web_search.wikipedia.language` / `max_pages` / `user_agent` | en / 2 / Filo/0.1 … | Wikipedia needs no key but asks for a descriptive User-Agent |
| `behavior.reprompt`, `behavior.followup_listen_seconds`, `behavior.conversation_turns` | true, 30, 4 | "anything else?" after answers; how long it listens for a follow-up; how many turns it remembers |
| `behavior.reprompt_phrases`, `behavior.farewell_phrases` | lists | what Filo says after an answer / on "bye filo" |
| `wake_word.enabled`, `wake_word.phrase`, `wake_word.bye_phrase`, `wake_word.silence_ms` | true, `hey filo`, `bye filo`, 1500 | always-on wake word, the goodbye phrase, the pause that ends a question |
| `hotkey.key`, `hotkey.modifiers` | `space`, `["option"]` | push-to-talk key |
| `default_profile`, `profiles_dir` | `sekiro`, `profiles` | which game's notes to load; a running game switches profiles by app name |
| `helper.path`, `helper.port`, `helper.allow_server_speech`, `helper.locale` | … | native helper settings |
| `tts.provider` | `auto` | `auto` = Kokoro when installed, else the system voice; or `kokoro` / `system` |
| `tts.voice`, `tts.rate`, `tts.volume` | `Ava, Zoe, Samantha`, 1.0, 70 | system voice: the first installed name wins, best quality variant preferred |
| `tts.kokoro.voice`, `tts.kokoro.speed` | `af_heart`, 1.05 | Kokoro voice and pace |
| `overlay.corner`, `overlay.margin`, `overlay.width`, `overlay.height` | bottom_right, 24, 620, 420 | where the overlay sits, in points |
| `mascot.internal_resolution`, `mascot.size`, `mascot.dither`, `mascot.vertex_jitter` | 96, 200, 0.09, 0 | the PS1 look: render size in pixels, on-screen size in points, dither strength, optional vertex wobble |
| `behavior.idle_timeout`, `behavior.answer_linger`, `behavior.greet_on_launch` | 25, 12, true | timings |
| `screen_reading.enabled` | false | Phase 1+; only draws the eye glint for now |

**Voices.** Two free options, both offline:

- **Kokoro (recommended)** — a small open-source neural voice that sounds far more natural than
  the built-in one. Install once with `scripts/setup_voice.sh` (~340 MB, Python venv under
  `tts/`); Filo starts it automatically and falls back to the system voice if it is missing.
  `tts.kokoro.voice` picks the voice (`af_heart`, `af_bella`, `am_michael`, …) and
  `tts.kokoro.speed` the pace.
- **Apple premium voice** — download "Ava (Premium)" or "Zoe (Premium)" once in System Settings ›
  Accessibility › Spoken Content › System Voice › Manage Voices; Filo picks it up automatically
  when `tts.provider` is `system` (or Kokoro is not installed).

Run-time flags after `--`: `--showcase`, `--ask "question"`, `--mute`, `--no-helper`,
`--no-greet`, `--capture-dir DIR`, `--quit-after N`, `--profile ID`, `--verbose`,
`--list-voices`, `--test-hotkey`.

## Layout

```
app/       Godot project: core/ (config, window, helper bridge) · mascot/ (mesh, shaders, animator, face sprites)
           brain/ (retriever, Claude + NIM clients, pipeline, speaker) · ui/ (bubble, input) · tests/
helper/    Swift helper: global hotkey (Carbon), wake word + follow-up listening + push-to-talk (on-device Speech), running apps
tts/       kokoro_server.py — optional local neural voice (venv + models created by scripts/setup_voice.sh)
native/    filo_overlay.m — GDExtension so the overlay floats over full-screen apps
profiles/  sekiro/ — profile.json + sample notes (Phase 1 fills in the full curated knowledge base)
docs/      animations.md · architecture.md · phase0-test-checklist.md
scripts/   run.sh · build_helper.sh · build_native.sh · setup_voice.sh · test.sh (+ fake_helper.py, mock_api.py)
```

## Troubleshooting

- **Nothing appears over a full-screen app** — run `scripts/build_native.sh` (the tiny extension
  that lets the cube float over full-screen apps) and check the terminal for
  `[filo_overlay] running as an accessory app` and `… now joins all Spaces`. Filo has no Dock
  icon or menu while it runs; quit with Ctrl-C in the terminal or `/quit` in the typed box.
- **The key does nothing** — check `~/Library/Logs/Filo/helper.log`: a press logs `hotkey down`.
  If nothing logs, another app owns ⌥ Space; change `hotkey` in config.json.
- **"Microphone / Speech recognition is off"** — System Settings › Privacy & Security › enable Filo Helper. Rebuilding the helper can re-prompt.
- **"The hotkey helper didn't connect"** — run `scripts/build_helper.sh`; the overlay stays clickable so you can still click the cube and press Space to type.
- **"…rejected the API key"** — check `.env`; without a usable key Filo answers from the notes only.
- **Wikipedia fallback didn't fire** — it only runs when the notes' confidence is below
  `web_search.confidence_threshold`; with Claude, Claude's own web search is used instead.
- **Voice sounds robotic** — install Kokoro with `scripts/setup_voice.sh`, or download a premium Apple voice (see Voices).
