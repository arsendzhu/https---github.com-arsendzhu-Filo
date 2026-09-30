# Overnight progress

Working branch: `overnight/0929-run` (never pushed). Gate: `./scripts/verify.sh` (runs `scripts/extra_checks.sh`, which runs `scripts/test.sh` and, later, `scripts/test_audio.sh`).

## Step 0 - what the repo actually looks like (the task text assumed a Python backend; the code is different)

| thing | where |
| --- | --- |
| Language split | Godot 4.7 / GDScript (`app/`) is the whole brain + UI. Swift helper (`helper/Sources/`) is the only macOS-native process (global hotkey, mic capture, on-device speech recognition, wake word). Python exists only for tests/mocks (`scripts/mock_api.py`, `scripts/fake_helper.py`) and the Kokoro TTS server (`tts/kokoro_server.py`). There is **no Python NIM client and no Python IPC peer**: "Python side" in the task == the Swift helper (audio/STT) or GDScript (brain). |
| NIM client + model string | `app/brain/nim_client.gd` (`ask()`, `chat()` for the tool loop, `list_models()`); default model in `app/core/filo_config.gd` (`nim.model`, `research.models`). Key from `NVIDIA_API_KEY` (env or `.env`, loaded by `FiloConfig.load_default`), never logged. |
| Retrieval / confidence | `app/brain/retriever.gd` (BM25 over profile notes, confidence 0..1), gate `web_search.confidence_threshold` = 0.45 in `app/brain/answer_pipeline.gd`. |
| Wiki client | `app/brain/wikipedia_client.gd` (Wikipedia REST + generic MediaWiki `mw_search`/`mw_page`/`mw_probe`; Fandom/wiki.gg use the same API). Game -> wiki mapping: `research.wikis` in config + `wiki` in `profiles/<id>/profile.json`. |
| Tool loop | `app/brain/research_agent.gd` (chain of NIM models, tools `wiki_search`, `wiki_page`, `web_search`, `fetch_page` via `app/brain/web_tools.gd`, caps 4 rounds / 6 tools, cache, breaker, 429 backoff, Claude fallback). |
| Audio capture / STT / VAD | Swift: `helper/Sources/AudioSource.swift` (AVAudioEngine tap), `SpeechCapture.swift` (push-to-talk, SFSpeechRecognizer on-device), `WakeListener.swift` ("hey filo" + open listening + end-of-question by transcript silence), `HelperController.swift`. There is no energy VAD anywhere; end of speech = transcript unchanged for `wake_word.silence_ms` (1500). |
| Godot main scene / overlay window | `app/main.tscn` -> `app/main.gd` (state machine), `app/core/overlay_window.gd` (borderless transparent always-on-top window, whole-window click-through), `native/filo_overlay.m` (accessory-app / all-Spaces GDExtension), UI in `app/ui/`. |
| IPC | Godot listens on 127.0.0.1:47821, the helper connects; newline-delimited JSON (`app/core/helper_bridge.gd` <-> `helper/Sources/Bridge.swift`). Protocol table in `docs/architecture.md`. |
| Tests | `scripts/test.sh` = Godot headless unit tests (`app/tests/run_tests.gd`) + offline end-to-end scenarios against `scripts/mock_api.py` with the scripted `scripts/fake_helper.py` + showcase captures. `pytest` (repo `.venv`) for python-side tests in `tests/`. |
| Environment quirks | macOS has no `timeout` binary, so the Godot step inside `verify.sh` is vacuous; the real Godot gate is `scripts/extra_checks.sh`. `NVIDIA_API_KEY` is not exported in the agent shell and `.env` must not be read, so live benchmarks only run when the user exports the key. |

Interface rule from the task ("ask before breaking the Python<->Godot interface"): the bridge protocol was only *extended* (new commands/events), never changed.

## Workstream 1 - tool use not triggering

### Root causes (all four were real, found by reading the code and reproducing with a scripted model)
1. `tool_choice` was hard-wired to `"auto"`, so a chat model that "knows" the answer (Terraria's Eye of Cthulhu) simply answers from memory: 0 tool calls (I saw `rounds=1 tools=0` live with the Lordvessel question on the previous session's run).
2. The game was always the loaded profile ("Sekiro"): the system prompt said "the player is playing Sekiro", the notes of that profile were fed in for a Terraria question, and a spurious confident note match (BM25 on "second phase", "beat") could skip the tool loop entirely (a follow-up in a Terraria session answered from Sekiro notes at confidence 1.00 - caught by the new follow-up test).
3. Game -> wiki mapping only knew the four hard-coded games; any other game got `wiki_search` -> "no wiki configured" (an error string, silently degrading to model memory).
4. No routing at all: small talk / commands and factual questions took the same path, and nothing logged *why* tools were or were not used.

### Changes
- `app/brain/query_router.gd` (new, pure/static): `classify` (command / smalltalk / factual), `detect_game` (known aliases first, then "in <Capitalised Name>" guess), `rewrite` (conversational question -> wiki + web query, follow-up resolution), `same_game`.
- `app/brain/session_memory.gd` (new): current game, last turns, last topic; cleared on game change or 15 min idle (`session.idle_reset_seconds`).
- `app/brain/answer_pipeline.gd`: routing with a log line per decision (`[req N] route: local notes | tool loop - <reason> | small talk | command | standard fallback`), game resolution, notes ignored when they belong to another game, tool loop for every factual question without a confident local answer, session memory wired in, canned small talk fallback.
- `app/brain/research_agent.gd`: first-round `tool_choice="required"` (mode `research.force_first_tool`: `required` | `synthetic` | `off`), per-model degrade to `auto` on 400/422, and **app-side forced first search** when the model still answers without a tool (wiki_search for a known wiki, else web_search); per-tool call/result logging with arguments; wiki discovery (`resolve_site`: unknown game -> web search for "<game> wiki" -> probe `api.php` -> remember in `user://discovered_wikis.json`); one-line wiki config (`"terraria": "https://terraria.wiki.gg"`); Terraria, Minecraft, Stardew Valley added.
- `app/main.gd`: voice commands (`stop`, `mute`, `unmute`, `repeat`) handled locally.
- Tests: `_test_router`, `test_unknown_game_still_uses_tools` (5 cases: forced call, model ignores the instruction, API rejects `required`, configured-wiki game, discovery), `_test_routing_paths` (starter game, confident local answer skips tools, small talk/commands skip tools, tool error, NIM down -> Claude, both down), `test_followup_uses_session_context`; e2e scenario 2f in `scripts/test.sh` reproduces the exact bug with a "lazy" mock model.

### Test expectation changes (justified, not weakened)
`scripts/test.sh` 2c/2e matched log strings that the routing work renamed (`Research failed` -> `route: tool loop failed`, `researching with tools` -> `route: tool loop`). Scenario 2c's Wikipedia query check changed from `Sekiro: Shadows Die Twice Who is Ganon in Zelda?` to `Zelda Who is Ganon in Zelda?`: the game is now taken from the question instead of blindly from the loaded profile, which is the intended fix. Same coverage, updated to the new behaviour.

### Not verifiable overnight
- Whether NIM's DeepSeek/Nemotron accept `tool_choice: "required"`: needs a live call (`scripts/bench_live.py`, only with the user's key). The code handles both outcomes (degrade + app-side forced search), so behaviour is correct either way; only latency differs.

## Incident: one accidental live NIM call (logged as required by the rules)
While building the UI test (workstream 2) I ran `app/tests/ui_tests.gd` once by hand without fake keys. The app loads the project's `.env` by itself (the normal mechanism), so two typed/voice test questions were answered by the real NIM (`provider=nim`, local-notes route: at most 2 chat requests). I did not read `.env`; the key was never printed. Fix: the UI test (and `scripts/test.sh` scenario 2g) now run with fake keys in the environment (environment beats `.env`) and every base URL pointed at a closed local port, so no test can reach a real API. The only live calls allowed remain `scripts/bench_live.py`'s.

## Workstream 2 - overlay controls missing / not clickable

### Root causes
1. **Not visible on first launch**: the only controls (voice mute, follow-up mode) were children of the speech bubble, which is `visible=false, alpha 0` until Filo speaks, and the mode button was additionally hidden until the first answer. A freshly launched Filo had nothing to click. There was no typing button and no mic mute at all.
2. **Not clickable**: `Main._update_click_regions()` wrote the control rects (window-local *points*, from `Control.get_global_rect()`) into `Window.mouse_passthrough_polygon`, which Godot applies in window *pixels*. With `content_scale_factor = 2.0` (Retina) the region was half the size and shifted toward the top-left, so it never covered the buttons and every click fell through to the game. (Inferred from Godot/macOS behaviour and the launch log - a `1240x840 px` window for a `620x420 pt` layout - not reproducible without a real click; see MANUAL_TESTS.md.)
3. **Typing never returned focus**: closing the typed box only called `_update_click_regions()`; `unfocusable` stayed false after the first typing session (the overlay could keep grabbing keyboard focus from the game) and nothing handed focus back.
4. **Mute**: nothing muted the capture side. The existing speaker button only muted Filo's *voice*.

### Changes
- New always-visible `ControlBar` (mic mute, voice mute, follow-up mode, type) on a dark pill next to the cube; buttons are `mouse_filter=STOP`, the pill itself `PASS`. Controls removed from the bubble.
- `ClickRegion` (pure geometry) + `Main._apply_window_mode()`: per frame, cursor position (screen px) -> window points with the *live* display scale -> flip the whole-window `mouse_passthrough` only while over a control. The polygon is no longer used. `Main.apply_scale` re-sizes the window in points when the display scale changes.
- Typing: `focus_save` before Filo activates, field focus, `focus_restore` on close, window back to click-through + unfocusable. Same `_ask()` path as voice (`question_asked(text, source)`).
- Mute: `set_mute{muted}` over the bridge; the helper stops the wake listener, push-to-talk and the audio engine, acknowledges with `mute_state`; the button turns red and struck through, the bubble explains; backup hotkey `control+option+M` (`hotkey_mute`, empty key disables) reported back as `mute_state{source:hotkey}`. A hold while muted answers with a notice; a tap still opens the text box.
- Helper (Swift): second Carbon hotkey (ids distinguished), mute state, front-app tracking + `focus_restore`. It compiles (`swiftc` to a temp dir); **the installed helper app is not rebuilt** (MANUAL_TESTS.md step 0: rebuilding re-signs it and may re-prompt for Microphone/Speech permission).
- Tests (`app/tests/ui_tests.gd`, run by `scripts/test.sh` 2g, real main scene + real helper process over the real TCP bridge): `test_ui_controls_visible_on_launch`, `test_passthrough_covers_controls` (region covers every control; cursor -> decision at scales 1/2/3; the old half-size bug; show/hide; resize; DPI change), mute round trip (the command arrives at the helper process, the ack is matched, hotkey mirror), typing round trip (focus_save/focus_restore, field focus, window mode, typed and voice questions share `_ask`).

### Test expectation changes (justified)
- `_test_bubble_controls`: "mode button starts hidden until the first answer" -> "starts visible": the task explicitly requires every control visible on launch. The polygon helper `Main.rect_to_polygon` and its test are kept (unused by the window).
- Headless Godot cannot read Window flags back (they reset to false after the first frame under the dummy display server), so tests assert `Main.window_state`, the mode the code requests from the OS.
- `app/tests/run_tests.gd` fixture: a 42-char fake `nvapi-...` string shortened to `nvapi-fixture` because `verify.sh`'s key scan flags any `nvapi-` + 20 chars (it was not a real key: it contained "test"/"abc").

### Cannot verify overnight
- The real `NSWindow.ignoresMouseEvents` behaviour and a real mouse click (no Accessibility permission, no clicking). Covered by MANUAL_TESTS.md.

