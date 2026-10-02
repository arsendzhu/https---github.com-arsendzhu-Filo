# Privacy: what stays on your machine and what leaves it

Filo is a local app. This is the complete list.

## Stays on your machine
- **Your voice.** Speech recognition is Apple's on-device recogniser (`requiresOnDeviceRecognition`); audio never goes to a server
  unless you set `helper.allow_server_speech` (off by default, and only used when on-device recognition is unavailable).
- **The audio buffer.** The helper keeps the last ~450 ms of microphone audio in memory so the first syllable is not lost. It is
  never written to disk, never sent anywhere, dropped whenever Filo speaks, when the mic is muted or after a finished question.
- **Debug audio is off by default.** Only with `"debug": {"save_audio": true}` are utterances saved (16 kHz WAV, in `logs/audio/`,
  the newest 20 kept, older ones deleted automatically). Turn it off again when you are done.
- **The microphone.** macOS shows its orange indicator whenever it is in use. Muting (button, `⌃⌥M` or `/mic off`) stops the audio
  engine completely; the panic hotkey (`⌃⌥H`) also mutes and hides Filo.
- **History and session memory.** The last 10 questions/answers (history panel) and the last few turns (follow-ups) live in memory
  for the session; nothing is written to disk. `settings.json` holds only settings (volume, hotkeys, mute state, game, ...).
- **Game detection** reads the names of running apps, locally. Filo never takes screenshots or reads the screen (that is a later
  phase and is off).
- **Voice output.** The Kokoro neural voice and the acknowledgement clips are generated locally.

## Leaves your machine (only when you ask a question that needs it)
| what | to whom | when |
| --- | --- | --- |
| the **transcript text** of your question, the game name, the last few turns of the conversation, and note passages that matched | NVIDIA NIM (`integrate.api.nvidia.com`) or Anthropic (Claude), whichever your key is for | a question that is not answered from the local notes alone (and for small talk) |
| **search queries** and page requests (game name + key words, wiki page titles, URLs the model chose to read) | the game's wiki (Fandom, wiki.gg, ...), DuckDuckGo for web search, and the sites the model reads | the tool loop (`wiki_search`, `wiki_page`, `web_search`, `fetch_page`); each carries a `User-Agent: Filo/0.1` header |
| Wikipedia search terms | Wikipedia | the fallback when the tool loop is unavailable |
| your **API key** | only the API it belongs to, in an `Authorization` header | every request to that API; it is never logged or printed |

Not sent anywhere: raw audio, your settings file, your history, file contents, screenshots, or your `.env`.
Tool results (web pages) are treated as untrusted data: they can never trigger app actions, file access or key disclosure.

## Controlling it
- No key at all: Filo answers from the local notes only and sends nothing.
- `research.enabled: false` stops the tool loop (no wiki/web requests); `web_search.enabled: false` stops the Wikipedia fallback.
- `python3 scripts/doctor.py --offline` checks the setup without touching the network.
