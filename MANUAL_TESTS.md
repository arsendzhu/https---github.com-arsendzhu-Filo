# Manual tests (things a script cannot click)

Written overnight; fill-in sections are added per workstream. Run `scripts/run.sh` (with your `.env`) for all of these.

## 1. Any-game questions use the tools (workstream 1)
1. Launch, say "hey filo" (or hold the hotkey) and ask: "How do I beat the Eye of Cthulhu in Terraria?"
2. In the terminal expect, in this order: `[req N] game='Terraria' (known)`, `route: tool loop`, `Tool call: wiki_search({"game":"Terraria","query":"Eye of Cthulhu"})`, `Tool result: wiki_search ok`, `Research done: ... tools>=1`.
3. Filo answers in one or two spoken sentences and the bubble footer shows the wiki page title (not a URL).
4. Ask about a game that is not in the config, e.g. "Who is the Hollow Knight's final boss in Hollow Knight?" - expect `No wiki configured ... searching the web`, then either `Discovered a MediaWiki API for 'Hollow Knight'` or a `web_search`/`fetch_page` sequence.
5. Say "thanks!" - expect `route: small talk - tools skipped`. Say "stop" while it talks - it goes quiet immediately.
