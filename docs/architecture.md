# Architecture (Phase 0)

```
repo/
  app/          Godot 4.7 project — the cross-platform core (overlay, mascot, brain, UI)
  helper/       Swift — the only macOS-specific process (hotkey, wake word, speech, running apps)
  profiles/     one folder per game: notes + profile.json (nothing generic lives here)
  scripts/      run / build / test
  .env          your API keys (see .env.example; git-ignored) · config.json for everything else
```

**The one rule:** nothing game-specific in `app/`, nothing generic in `profiles/`.

## Runtime pieces

| piece | file | role |
| --- | --- | --- |
| overlay window | `app/core/overlay_window.gd` | borderless, transparent, always-on-top, click-through (`Window.mouse_passthrough` → `NSWindow.ignoresMouseEvents`), never focused except while the typed panel is open; sized in points × backing scale, parked in a screen corner |
| full-screen overlay | `native/filo_overlay.m` → `app/filo_overlay.gdextension` | a small GDExtension (no godot-cpp). Measured on macOS 26: a regular app's NSWindow never joins another app's full-screen Space, an accessory app's does. So it switches the running project to an accessory app (no Dock icon), marks Godot's window *can join all Spaces* + *full-screen auxiliary* + *stationary*, and raises it to the status-window level. Skipped in the editor. Built by `scripts/build_native.sh` |
| mascot | `app/mascot/` | low-res 3D render → nearest upscale → palette/dither; see `animations.md` |
| helper bridge | `app/core/helper_bridge.gd` | TCP server on 127.0.0.1:47821, newline-delimited JSON, launches the helper |
| config | `app/core/filo_config.gd` | defaults ← config.json ← .env ← environment ← command line; picks the LLM provider |
| answer pipeline | `app/brain/answer_pipeline.gd` | retrieval → confidence → (web search) → LLM → text, spoken text, sources |
| retriever | `app/brain/retriever.gd` | BM25 over note chunks (~90 words), light stemming, stopwords for question filler |
| Claude client | `app/brain/claude_client.gd` | raw HTTP to `api.anthropic.com/v1/messages` (web search, refusal fallbacks) |
| NIM client | `app/brain/nim_client.gd` | OpenAI-compatible chat completions on `integrate.api.nvidia.com/v1` |
| speaker | `app/brain/speaker.gd` | two voices: local Kokoro neural TTS (`tts/kokoro_server.py`, one request for the whole utterance so nothing can gap or stall mid-speech, mouth follows the audio envelope, text reveal follows time) or Godot `DisplayServer` TTS (AVSpeechSynthesizer, word boundaries drive mouth + reveal); `auto` prefers Kokoro when installed. A watchdog in `main.gd` forces completion if a provider ever fails to report back, so the conversation loop can't get stuck |
| Wikipedia client | `app/brain/wikipedia_client.gd` | free web fallback for non-Claude providers: MediaWiki search + REST page summaries, proper User-Agent |
| UI | `app/ui/` | bubble (listening / thinking / answer / error / info), the typed-question panel, and the bubble's own sound/mode toggle buttons |
| controller | `app/main.gd` | the app state machine (below) |

## Clickable controls on a click-through overlay

The overlay is click-through everywhere by default (`Window.mouse_passthrough`), so the game
underneath always gets the click — except the bubble's two small buttons (mute, and the
voice/text follow-up switch) need to be clickable themselves. `Main._update_click_regions()`
runs every frame: it reads the buttons' current on-screen rect (`Control.get_global_rect()`,
already in the window's local point space) and writes it to `Window.mouse_passthrough_polygon`
— macOS then treats that one small region as normal and interactive, and leaves the window
click-through everywhere else. It's skipped whenever something else already needs the whole
window interactive (the typed-question panel, or the no-helper fallback), so it can never fight
those; property writes are skipped when the rect hasn't actually changed, to keep the per-frame
cost negligible.

## LLM providers

`llm.provider` is `auto` by default: Claude when a usable `ANTHROPIC_API_KEY` exists, otherwise
NVIDIA NIM when `NVIDIA_API_KEY` exists, otherwise notes-only answers. An `nvapi-…` key pasted
into `ANTHROPIC_API_KEY` is recognised and used as the NVIDIA key. Placeholders such as
`sk-ant-...` are ignored.

| | Claude | NVIDIA NIM |
| --- | --- | --- |
| default model | `claude-opus-5`, effort `low` | `nvidia/nemotron-3-super-120b-a12b`, reasoning off (`chat_template_kwargs.enable_thinking=false`, ~3 s answers instead of 8–16 s) |
| live web search when the notes don't cover a question | yes (`web_search_20260209` server tool) | no — the model answers from notes + its own knowledge and is told to say when unsure |
| refusal handling | `stop_reason: refusal` + server-side `fallbacks: "default"` | n/a |
| request | `POST /v1/messages` with `x-api-key` | `POST /chat/completions` with `Authorization: Bearer` |

## App state machine

```
ASLEEP --hold or "hey filo"--> WAKING --> LISTENING --release/silence + final--> THINKING --answer--> ANSWERING
ANSWERING --speech done--> reaction + "anything else?" --> LISTENING (follow-up, no wake phrase) --final--> THINKING ...
LISTENING (follow-up) --30 s silence--> IDLE (stays visible; "hey filo" or the key wakes it again)
any awake state --"bye filo" or tap--> farewell --> SLEEPING --> ASLEEP      ASLEEP --tap--> TYPING
```

Ordering details that matter: the helper starts capturing audio on key-down (or right after
the wake phrase) before the summon animation finishes, so a short question never loses its
first words. A `final` that arrives while still WAKING is queued and handled when the wake
ends. A hold or wake that ends with no recognised text goes back to idle with a "didn't catch
that" bubble. While Filo speaks, the wake listener is paused so it cannot wake itself.

## Helper protocol (helper → app)

| event | payload | meaning |
| --- | --- | --- |
| `ready` | hotkey, hotkey_registered, wake_word, speech{available,on_device,speech_auth,mic_auth} | helper is up |
| `hotkey_down` | | key pressed (auto-repeat filtered) |
| `tap` | duration_ms | released within 300 ms |
| `hotkey_up` | duration_ms | released after a real hold; a `final` follows |
| `wake_word` | phrase | the wake phrase was heard; partials and a `final` follow |
| `listen_timeout` | reason | follow-up listening ended in silence (nothing to answer) |
| `bye` | | "bye filo" (or "goodbye filo", "filo bye") was heard |
| `partial` / `final` | text | live transcript / finished transcript (empty if nothing was heard) |
| `level` | value 0..1 | mic RMS while listening (drives the pulse) |
| `apps` | apps[{name,bundle_id}] | running apps, for game detection |
| `error` | code, message | permission / device / recognition problems, shown in the bubble |

App → helper: `ping`, `list_apps`, `wake_pause`, `wake_resume`, `set_wake{enabled}`,
`listen_open{timeout_ms}` (capture the next utterance without a wake phrase, after "anything
else?"), `listen_stop`, `quit`, `simulate_hotkey{pressed}` (test hook).

### Inside the helper

- `HotKey` — Carbon `RegisterEventHotKey`; global, no Accessibility permission.
- `AudioSource` — one AVAudioEngine input tap shared by both listeners; runs only while someone consumes.
- `SpeechCapture` — push-to-talk session (on-device `SFSpeechRecognizer`), `final` on release.
- `WakeListener` — continuous on-device recognition; `WakeMatcher` looks for a trigger word
  ("hey", "okay", …) followed by the name or one of its sound-alikes ("filo", "philo", "fellow", …);
  after a match it keeps transcribing until 1.5 s of silence (or 15 s max), then sends `final`;
  sessions restart every 55 s and after each question; paused while Filo speaks.
- Push-to-talk takes over from the wake listener while the key is held and hands back afterwards.
- Logs go to `~/Library/Logs/Filo/helper.log`.

The helper is launched through `open -g -n -a "Filo Helper.app"` so macOS attributes the
microphone and speech-recognition permissions to the helper itself (macOS shows its orange
microphone indicator while the wake word listens), and it exits by itself when the socket closes.

## The answer step

1. `Retriever.search(question)` → top 4 chunks and a confidence in [0, 1].
2. Low confidence (below `web_search.confidence_threshold`, or no notes matched) → web fallback:
   - Claude provider: the `web_search` server tool is attached (max 2 uses).
   - Otherwise (NVIDIA NIM): `WikipediaClient` searches English Wikipedia (MediaWiki search,
     biased with the game name, plain question as a second try), fetches up to two REST page
     summaries (disambiguation and empty pages skipped) and appends them as extra numbered
     passages marked "Wikipedia:". No key; a descriptive User-Agent is always sent.
3. No provider → notes-only answer from the top passage (or the Wikipedia extract).
4. One request to the provider with the same prompt: answer only the narrow question, 1–3 spoken
   sentences, no spoilers beyond what was asked, prefer the notes, ground in Wikipedia when the
   notes are silent, use the recent conversation for follow-ups, end with `SOURCES: n, m`.
5. The `SOURCES:` marker (own line or inline) is stripped and mapped back to passage titles/URLs
   (kind `kb` or `web`); Claude web citations come from the response's `citations` blocks. Both
   show in the bubble's footer (`notes: …` / `web: … (en.wikipedia.org)`).
6. The last `behavior.conversation_turns` question/answer pairs are kept and sent as
   "Recent conversation" so "what about its second phase?" resolves; cleared when Filo sleeps.

Session context (last area / boss / item from screen reading) is a placeholder dictionary in the
pipeline; Phase 1 fills it.

## What is deliberately not here yet

- Screen reading / OCR (Phase 1–2). The glint cue exists; capture does not. `screen_reading.enabled` stays false.
- Windows: the Godot core is portable; the helper would need a Windows twin (global hotkey + STT + wake word).
- Exclusive-fullscreen games that capture the display (rare on modern macOS) cannot be overlaid
  by any window; borderless/full-screen-Space games can, thanks to the native overlay extension.
