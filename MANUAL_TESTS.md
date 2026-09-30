# Manual tests (things a script cannot click)

Written overnight; fill-in sections are added per workstream. Run `scripts/run.sh` (with your `.env`) for all of these.

## 1. Any-game questions use the tools (workstream 1)
1. Launch, say "hey filo" (or hold the hotkey) and ask: "How do I beat the Eye of Cthulhu in Terraria?"
2. In the terminal expect, in this order: `[req N] game='Terraria' (known)`, `route: tool loop`, `Tool call: wiki_search({"game":"Terraria","query":"Eye of Cthulhu"})`, `Tool result: wiki_search ok`, `Research done: ... tools>=1`.
3. Filo answers in one or two spoken sentences and the bubble footer shows the wiki page title (not a URL).
4. Ask about a game that is not in the config, e.g. "Who is the Hollow Knight's final boss in Hollow Knight?" - expect `No wiki configured ... searching the web`, then either `Discovered a MediaWiki API for 'Hollow Knight'` or a `web_search`/`fetch_page` sequence.
5. Say "thanks!" - expect `route: small talk - tools skipped`. Say "stop" while it talks - it goes quiet immediately.

## 0. Rebuild the helper first (needed for mute, the mute hotkey, focus hand-back and the audio fixes)
`scripts/build_helper.sh` recompiles and re-signs `helper/build/Filo Helper.app`. macOS may ask again for **Microphone** and **Speech Recognition** access: allow both. (Not done overnight so your existing permissions were left alone.) `scripts/build_native.sh` is unchanged.

## 2. Control bar: visible, clickable, click-through elsewhere (workstream 2)
1. Launch `scripts/run.sh` and do **not** say anything. Within a second a small dark bar with four icons (microphone, speaker, sound-waves, speech bubble) is visible left of where the cube appears, bottom-right of the screen. It stays visible after the cube spins out. If it is missing, check the terminal and note the scale in the `Overlay window:` log line.
2. Hover an icon: the tooltip appears and the cursor becomes a hand. Move the mouse just outside the bar and click something behind it (a desktop icon, a game window): the click must reach the app behind. Move back onto the bar: it must take the click.
3. **Mic mute**: click the microphone. It turns red with a slash, the bubble says "Microphone muted...", and the orange macOS microphone dot goes away within a couple of seconds. Say "hey filo": nothing happens. Hold the hotkey: a notice says the mic is muted. Press `control+option+M`: the mic comes back (the button un-slashes). Press it again to mute, click the button to unmute.
   - Terminal: `Microphone muted (button)` then `Helper reports microphone muted (command)`; no `did not confirm` warning.
4. **Voice mute** (speaker): while Filo is speaking an answer, click it - speech stops at once, the text stays.
5. **Typing**: put another app in front (a text editor, or the game). Click the speech-bubble icon: Filo wakes, a text box appears and you can type immediately. Type `who is lady butterfly` + Enter: it answers like a voice question. Press Esc or click the icon to close it and check the app you had in front is active again (typing goes into it, not into Filo).
6. **Follow-up mode** (sound-waves icon): click it, it becomes a keyboard; after the next answer "anything else?" opens the text box instead of the mic.
7. **Full screen**: repeat 1-3 with a full-screen app (borderless windowed for games; exclusive full screen cannot show any overlay).
