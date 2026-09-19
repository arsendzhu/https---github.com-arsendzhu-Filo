class_name AnswerPipeline
extends Node
## question -> notes retrieval -> web fallback when confidence is low (Claude's
## web search, or free Wikipedia for NVIDIA NIM) -> LLM -> {text, spoken, sources}.
## Keeps a short conversation history so follow-up questions resolve, and
## falls back to reading the best passage aloud when no LLM key is configured.

var cfg: FiloConfig
var profile: GameProfile
var retriever := Retriever.new()
var claude: ClaudeClient
var nim: NimClient
var wikipedia: WikipediaClient
var provider := "none"                 # anthropic | nim | none
var history: Array = []                # [{q, a}], most recent last
var max_history := 4
var session_context: Dictionary = {}   # Phase 1+: last_area, last_boss, ...


func setup(config: FiloConfig, game_profile: GameProfile) -> void:
	cfg = config
	if claude == null:
		claude = ClaudeClient.new()
		claude.name = "ClaudeClient"
		add_child(claude)
	if nim == null:
		nim = NimClient.new()
		nim.name = "NimClient"
		add_child(nim)
	if wikipedia == null:
		wikipedia = WikipediaClient.new()
		wikipedia.name = "WikipediaClient"
		add_child(wikipedia)
	claude.configure(cfg)
	nim.configure(cfg)
	wikipedia.configure(cfg)
	provider = cfg.provider()
	max_history = maxi(0, int(cfg.get_value("behavior.conversation_turns", 4)))
	set_profile(game_profile)


func set_profile(game_profile: GameProfile) -> void:
	profile = game_profile
	retriever.build(profile)
	FiloLog.info("Profile '%s' (%s): %d notes, %d chunks" % [profile.id, profile.name, profile.notes.size(), retriever.chunks.size()])


func clear_history() -> void:
	history.clear()


func llm_label() -> String:
	match provider:
		"anthropic":
			return "Claude (%s, effort %s)" % [claude.model, claude.effort]
		"nim":
			return "NVIDIA NIM (%s)" % nim.model
		_:
			return "notes only — no usable API key"


## Which web fallback applies: "anthropic" (Claude's server-side web search),
## "wikipedia" (free MediaWiki + REST summaries) or "off".
func web_provider() -> String:
	if not bool(cfg.get_value("web_search.enabled", true)):
		return "off"
	var wiki_ok: bool = bool(cfg.get_value("web_search.wikipedia.enabled", true))
	match str(cfg.get_value("web_search.provider", "auto")).to_lower():
		"auto":
			if provider == "anthropic":
				return "anthropic"
			return "wikipedia" if wiki_ok else "off"
		"anthropic", "claude":
			return "anthropic" if provider == "anthropic" else "off"
		"wikipedia", "wiki":
			return "wikipedia" if wiki_ok else "off"
		_:
			return "off"


func web_label() -> String:
	match web_provider():
		"anthropic":
			return "Claude web search"
		"wikipedia":
			return "Wikipedia"
		_:
			return "off"


func ask(question: String) -> Dictionary:
	var threshold: float = float(cfg.get_value("web_search.confidence_threshold", 0.45))
	var r := retriever.search(question, 4)
	var passages: Array = r.results.duplicate()
	var low_confidence: bool = passages.is_empty() or r.confidence < threshold
	var web := web_provider()
	var use_claude_web := web == "anthropic" and low_confidence
	var wiki_used := false
	if web == "wikipedia" and low_confidence:
		FiloLog.info("Notes confidence %.2f is below %.2f — asking Wikipedia" % [r.confidence, threshold])
		var w: Dictionary = await wikipedia.search_and_summarize(question, profile.name if profile else "")
		if w.ok:
			var titles := PackedStringArray()
			for e in w.results:
				passages.append({"chunk": {"title": e.title, "source": e.url, "text": e.text, "kind": "web"}, "score": 0.0})
				titles.append(e.title)
			wiki_used = true
			FiloLog.info("Wikipedia: %d page(s): %s" % [w.results.size(), ", ".join(titles)])
		else:
			FiloLog.warn("Wikipedia fallback failed: " + str(w.error))
	var fallback_note := "off"
	if use_claude_web:
		fallback_note = "Claude web search"
	elif wiki_used:
		fallback_note = "Wikipedia"
	elif low_confidence and web != "off":
		fallback_note = web + " (nothing found)"
	FiloLog.info("Retrieval: %d note passages, confidence %.2f, web fallback %s" % [r.results.size(), r.confidence, fallback_note])
	if provider == "none":
		return _kb_only(passages, r.confidence)
	var sys := system_prompt(use_claude_web, wiki_used)
	var user := user_content(question, passages)
	var resp: Dictionary
	if provider == "nim":
		resp = await nim.ask(sys, user)
	else:
		var tools := []
		if use_claude_web:
			tools.append({"type": "web_search_20260209", "name": "web_search", "max_uses": int(cfg.get_value("web_search.max_uses", 2))})
		resp = await claude.ask(sys, user, tools)
	if not resp.ok:
		return {"ok": false, "error": resp.error, "used_web": use_claude_web or wiki_used, "confidence": r.confidence}
	var split := split_sources(resp.text)
	var sources := []
	for i in split.indices:
		if i >= 1 and i <= passages.size():
			var ch: Dictionary = passages[i - 1].chunk
			_add_source(sources, {"kind": str(ch.get("kind", "kb")), "title": ch.title, "url": ch.source})
	for c in resp.citations:
		_add_source(sources, {"kind": "web", "title": c.title, "url": c.url})
	if sources.is_empty() and use_claude_web:
		for s in resp.searched.slice(0, mini(2, resp.searched.size())):
			_add_source(sources, {"kind": "web", "title": s.title, "url": s.url})
	if sources.is_empty() and wiki_used:
		for p in passages:
			if str(p.chunk.get("kind", "kb")) == "web":
				_add_source(sources, {"kind": "web", "title": p.chunk.title, "url": p.chunk.source})
	var clean := clean_for_speech(split.text)
	_remember(question, clean)
	return {
		"ok": true,
		"text": clean,
		"spoken": clean,
		"sources": sources,
		"used_web": use_claude_web or wiki_used,
		"confidence": r.confidence,
		"model": resp.model,
		"provider": provider,
	}


func _remember(question: String, answer: String) -> void:
	if max_history <= 0:
		return
	history.append({"q": question, "a": answer})
	while history.size() > max_history:
		history.pop_front()


func _kb_only(passages: Array, confidence: float) -> Dictionary:
	if passages.is_empty():
		return {
			"ok": false,
			"error": "I don't have notes on that, and there's no API key configured to look further. Add NVIDIA_API_KEY or ANTHROPIC_API_KEY to .env.",
			"used_web": false,
			"confidence": 0.0,
		}
	var top: Dictionary = passages[0].chunk
	var snippet := _first_sentences(top.text, 2)
	var is_web := str(top.get("kind", "kb")) == "web"
	var text := ("No API key yet, so straight from Wikipedia on %s: %s" if is_web else "No API key yet, so straight from my notes on %s: %s") % [top.title, snippet]
	return {
		"ok": true,
		"text": text,
		"spoken": clean_for_speech(text),
		"sources": [{"kind": "web" if is_web else "kb", "title": top.title, "url": top.source}],
		"used_web": is_web,
		"confidence": confidence,
		"model": "notes-only",
	}


func system_prompt(use_web: bool, wiki_present: bool = false) -> String:
	var game_name := profile.name if profile else "the game"
	var lines := [
		"You are Filo, a portable wiki-style gaming companion: a general guide built to help with any game, not just one title. Right now you're helping the player with %s, answering out loud." % game_name,
		"Answer only what was asked, in one to three short spoken sentences (about 60 words max). No lists, no markdown, no preamble.",
		"Never reveal outcomes, endings, twists, or later content the player did not ask about. If the narrow answer truly requires a spoiler, say 'small spoiler ahead' first and keep it minimal.",
		"Prefer the player's notes (the numbered passages) when they cover the question — they're curated specifically for %s. If they don't cover it, or the question turns out to be about a different game entirely, answer from what you know like the general game wiki you are." % game_name,
	]
	if wiki_present:
		lines.append("Some passages come from Wikipedia; when the notes are silent, ground the answer in them and say if you're unsure.")
	if use_web:
		lines.append("If the notes don't cover the question, use web_search (at most two searches) and base the answer on what you find.")
	lines.append("The player may ask follow-up questions; use the recent conversation to resolve references like 'it', 'that boss' or 'the second phase'.")
	lines.append("Session context, when present, tells you where the player is right now; use it to disambiguate, don't repeat it back.")
	if profile and profile.persona_hint != "":
		lines.append(profile.persona_hint)
	lines.append("End your reply with a final line exactly like: SOURCES: 1, 3 — listing the passage numbers you actually used, or SOURCES: none if you used none.")
	return "\n".join(lines)


func user_content(question: String, passages: Array) -> String:
	var parts := ["Game: " + (profile.name if profile else "unknown")]
	if session_context.is_empty():
		parts.append("Session context: none")
	else:
		parts.append("Session context: " + JSON.stringify(session_context))
	if not history.is_empty():
		var turns := PackedStringArray()
		for h in history:
			turns.append("Player: %s\nFilo: %s" % [str(h.q), str(h.a).left(300)])
		parts.append("Recent conversation:\n" + "\n".join(turns))
	if passages.is_empty():
		parts.append("Notes: none matched this question.")
	else:
		parts.append("Notes:")
		for i in passages.size():
			var ch: Dictionary = passages[i].chunk
			var label := "Wikipedia: " if str(ch.get("kind", "kb")) == "web" else ""
			parts.append("[%d] %s%s — %s\n%s" % [i + 1, label, ch.title, ch.source, ch.text])
	parts.append("Question: " + question.strip_edges())
	return "\n\n".join(parts)


## Splits a trailing "SOURCES: 1, 3" marker off the answer text, whether the
## model put it on its own line or at the end of the last sentence.
static func split_sources(text: String) -> Dictionary:
	var indices: Array = []
	var body := text.strip_edges()
	var re := RegEx.new()
	re.compile("(?i)\\s*\\(?sources?\\s*:\\s*([0-9,\\s]*|none)\\)?\\.?\\s*$")
	var m := re.search(body)
	if m:
		var nums := RegEx.new()
		nums.compile("\\d+")
		for n in nums.search_all(m.get_string(1)):
			indices.append(int(n.get_string()))
		body = body.substr(0, m.get_start()).strip_edges()
	return {"text": body, "indices": indices}


## Strips markdown-ish symbols so text-to-speech does not read them out.
static func clean_for_speech(text: String) -> String:
	var t := text
	for sym in ["**", "__", "`", "#", "*", "_"]:
		t = t.replace(sym, "")
	var re := RegEx.new()
	re.compile("\\[([^\\]]+)\\]\\([^)]*\\)")
	t = re.sub(t, "$1", true)
	var ws := RegEx.new()
	ws.compile("[ \\t]+")
	t = ws.sub(t, " ", true)
	return t.strip_edges()


static func _first_sentences(text: String, count: int) -> String:
	var flat := text.replace("\n", " ")
	var re := RegEx.new()
	re.compile("[^.!?]+[.!?]")
	var out := ""
	var n := 0
	for m in re.search_all(flat):
		out += m.get_string().strip_edges() + " "
		n += 1
		if n >= count:
			break
	return out.strip_edges() if out != "" else flat.left(220)


static func _add_source(list: Array, s: Dictionary) -> void:
	for e in list:
		if e.title == s.title and e.url == s.url:
			return
	list.append(s)
