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
var web_tools: WebTools
var research: ResearchAgent
var provider := "none"                 # anthropic | nim | none
var session := SessionMemory.new()     # current game, recent turns, last topic (follow-ups)
var history: Array:                    # [{q, a, topic}], most recent last
	get:
		return session.turns
var max_history: int:
	get:
		return session.max_turns
	set(v):
		session.max_turns = v
var session_context: Dictionary = {}   # Phase 1+: last_area, last_boss, ...
var pattern_game_local_confidence := 0.8   # notes must be this sure to answer about a game we only guessed from the wording
var _req_seq := 0


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
	if web_tools == null:
		web_tools = WebTools.new()
		web_tools.name = "WebTools"
		add_child(web_tools)
	if research == null:
		research = ResearchAgent.new()
		research.name = "ResearchAgent"
		add_child(research)
	claude.configure(cfg)
	nim.configure(cfg)
	wikipedia.configure(cfg)
	web_tools.configure(cfg, wikipedia)
	research.setup(cfg, nim, claude, wikipedia, web_tools)
	provider = cfg.provider()
	max_history = maxi(0, int(cfg.get_value("behavior.conversation_turns", 4)))
	session.idle_reset_seconds = float(cfg.get_value("session.idle_reset_seconds", 900))
	pattern_game_local_confidence = float(cfg.get_value("research.pattern_game_local_confidence", 0.8))
	set_profile(game_profile)
	if research.is_available():
		FiloLog.info("Research (tool-calling) chain: " + research.chain_label())
		research.call_deferred("startup")   # async model check + warm-up, never blocks a question


func set_profile(game_profile: GameProfile) -> void:
	profile = game_profile
	if research != null:
		research.set_profile(game_profile)
	retriever.build(profile)
	FiloLog.info("Profile '%s' (%s): %d notes, %d chunks" % [profile.id, profile.name, profile.notes.size(), retriever.chunks.size()])


func clear_history() -> void:
	session.clear()


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


## Routes one question. Every decision is logged as "[req N] route: ..." so a missing lookup is
## always explainable from the log: command / small talk (no tools), local notes (confident),
## tool loop (research agent) or the plain fallback.
## `on_sentence`: optional func(sentence: String), called while the tool-loop model is still writing its answer
## as soon as the first complete sentence exists (so speech can start early). Only the tool-loop route streams.
func ask(question: String, on_sentence: Callable = Callable()) -> Dictionary:
	_req_seq += 1
	var tag := "req %d" % _req_seq
	var kind := QueryRouter.classify(question)
	if kind == "command":
		var cmd := QueryRouter.command_for(question)
		FiloLog.info("[%s] route: command '%s' - tools skipped" % [tag, cmd])
		return _command_result(cmd)
	if kind == "smalltalk":
		FiloLog.info("[%s] route: small talk - tools skipped" % tag)
		return await _smalltalk(question, tag)

	var threshold: float = float(cfg.get_value("web_search.confidence_threshold", 0.45))
	var r := retriever.search(question, 4)
	var passages: Array = r.results.duplicate()
	var confidence: float = r.confidence

	# Which game is this about? A game we know (wiki table / profile) beats the loaded profile.
	var games: Array = research.known_games() if research != null else []
	var profile_name := profile.name if profile else ""
	var det := QueryRouter.detect_game(question, games)
	var game_name := session.game if session.game != "" else profile_name
	var mismatch := ""
	if det.name != "":
		if det.source == "known":
			game_name = det.name
			if profile_name != "" and not QueryRouter.same_game(det.name, profile_name, games):
				mismatch = "the question is about %s, the loaded notes are for %s" % [det.name, profile_name]
		elif profile_name == "" or not QueryRouter.same_game(det.name, profile_name, games):
			# only guessed from the wording ("... in Hollow Knight"): trust it unless the notes are very sure
			game_name = det.name
			if confidence < pattern_game_local_confidence:
				mismatch = "the wording suggests a different game (%s) and the notes are not sure enough" % det.name
	var reset := session.begin_question(game_name if det.name != "" else "")
	if reset != "":
		FiloLog.info("[%s] session memory cleared: %s" % [tag, reset])
	if game_name == "":
		game_name = session.game if session.game != "" else profile_name
	if mismatch == "" and profile_name != "" and not QueryRouter.same_game(game_name, profile_name, games):
		# a follow-up inside a session about another game: the loaded notes are for the profile's game only
		mismatch = "the current game is %s, the loaded notes are for %s" % [game_name, profile_name]
	if mismatch != "":
		FiloLog.info("[%s] notes ignored: %s" % [tag, mismatch])
		passages = []
		confidence = 0.0
	var same_game_topic := session.last_topic() if (det.name == "" or QueryRouter.same_game(det.name, session.game)) else ""
	var rw := QueryRouter.rewrite(question, game_name, same_game_topic)
	FiloLog.info("[%s] game='%s' (%s) query wiki='%s' web='%s'%s" % [tag, game_name, det.source if det.source != "" else "session/profile", rw.wiki, rw.web, " (follow-up)" if rw.followup else ""])

	var local_ok := not passages.is_empty() and confidence >= threshold
	var low_confidence := not local_ok
	if local_ok:
		FiloLog.info("[%s] route: local notes (confidence %.2f >= %.2f) - tools skipped" % [tag, confidence, threshold])
	elif research == null or not research.is_available():
		FiloLog.info("[%s] route: standard fallback - the tool loop is unavailable (%s)" % [tag, _research_unavailable_reason()])
	else:
		FiloLog.info("[%s] route: tool loop - %s" % [tag, mismatch if mismatch != "" else "no confident local answer (confidence %.2f < %.2f)" % [confidence, threshold]])
		var hints := {"force_tool": true, "wiki_query": rw.wiki, "web_query": rw.web, "game": game_name, "tag": tag, "on_sentence": on_sentence}
		var rr: Dictionary = await research.answer(user_content(question, passages, rw, game_name), game_name, hints)
		if rr.ok:
			FiloLog.info("[%s] done: route=tool_loop model=%s first_token=%dms model=%dms tools=%dms total=%dms rounds=%d tool_calls=%d" % [tag, rr.model, rr.get("ttft_ms", -1), rr.model_ms, rr.tool_ms, rr.total_ms, rr.rounds, rr.tool_calls])
			_remember(question, rr.text, rw.topic)
			return {
				"ok": true, "text": rr.text, "spoken": rr.text, "sources": rr.sources, "used_web": true,
				"confidence": confidence, "model": rr.model, "provider": "research", "route": "tool_loop", "game": game_name,
				"timing": {"total_ms": rr.total_ms, "first_response_ms": rr.first_response_ms, "model_ms": rr.model_ms, "tool_ms": rr.tool_ms, "rounds": rr.rounds, "tool_calls": rr.tool_calls},
			}
		FiloLog.warn("[%s] route: tool loop failed (%s) - using the standard fallback" % [tag, str(rr.error)])
	var web := web_provider()
	var use_claude_web := web == "anthropic" and low_confidence
	var wiki_used := false
	if web == "wikipedia" and low_confidence:
		FiloLog.info("[%s] Notes confidence %.2f is below %.2f - asking Wikipedia" % [tag, confidence, threshold])
		var w: Dictionary = await wikipedia.search_and_summarize(question, game_name)
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
	FiloLog.info("Retrieval: %d note passages, confidence %.2f, web fallback %s" % [passages.size(), confidence, fallback_note])
	if provider == "none":
		return _kb_only(passages, confidence)
	var sys := system_prompt(use_claude_web, wiki_used)
	var user := user_content(question, passages, rw, game_name)
	var resp: Dictionary
	if provider == "nim":
		resp = await nim.ask(sys, user)
	else:
		var tools := []
		if use_claude_web:
			tools.append({"type": "web_search_20260209", "name": "web_search", "max_uses": int(cfg.get_value("web_search.max_uses", 2))})
		resp = await claude.ask(sys, user, tools)
	if not resp.ok:
		return {"ok": false, "error": resp.error, "used_web": use_claude_web or wiki_used, "confidence": confidence}
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
	_remember(question, clean, rw.topic)
	return {
		"ok": true,
		"text": clean,
		"spoken": clean,
		"sources": sources,
		"used_web": use_claude_web or wiki_used,
		"confidence": confidence,
		"model": resp.model,
		"provider": provider,
		"route": "local" if local_ok else "fallback",
		"game": game_name,
	}


func _remember(question: String, answer: String, topic: String = "") -> void:
	session.note_turn(question, answer, topic)


func _research_unavailable_reason() -> String:
	if research == null:
		return "no research agent"
	if not bool(cfg.get_value("research.enabled", true)):
		return "research.enabled is false"
	if nim == null or not nim.has_key():
		return "no NVIDIA_API_KEY"
	return "no research models configured"


## "stop" / "mute" / "unmute" / "repeat": handled by the app, no model, no tools.
func _command_result(cmd: String) -> Dictionary:
	var text := ""
	match cmd:
		"repeat":
			text = str(session.turns[-1].a) if not session.turns.is_empty() else "There's nothing to repeat yet."
		"mute":
			text = "Okay, muted."
		"unmute":
			text = "Voice is back on."
	return {"ok": true, "text": text, "spoken": text if cmd == "unmute" or cmd == "repeat" else "", "sources": [], "used_web": false,
		"confidence": 1.0, "model": "local", "provider": "local", "route": "command", "command": cmd}


## Small talk gets one short model reply (never tools), or a canned one when no model answers.
func _smalltalk(question: String, tag: String) -> Dictionary:
	var text := ""
	var model := "canned"
	if provider != "none":
		var sys := "You are Filo, a friendly little in-game companion who looks up game facts. The player is making small talk. Reply in one short, warm spoken sentence. Do not look anything up and do not use markdown."
		var resp: Dictionary
		if provider == "nim":
			resp = await nim.ask(sys, question)
		else:
			resp = await claude.ask(sys, question, [])
		if resp.ok:
			text = clean_for_speech(split_sources(resp.text).text)
			model = str(resp.get("model", ""))
		else:
			FiloLog.warn("[%s] small talk model failed (%s) - canned reply" % [tag, str(resp.error)])
	if text == "":
		text = canned_smalltalk(question)
	return {"ok": true, "text": text, "spoken": text, "sources": [], "used_web": false, "confidence": 1.0, "model": model, "provider": provider, "route": "smalltalk"}


static func canned_smalltalk(question: String) -> String:
	var n := QueryRouter.normalize(question)
	if n.contains("thank") or n in ["nice", "great", "cool", "awesome", "perfect", "cheers"]:
		return "Anytime!"
	if n.contains("bye") or n.contains("night") or n.contains("see you") or n == "later":
		return "See you out there!"
	if n.contains("who are you") or n.contains("what are you") or n.contains("your name") or n.contains("what can you do") or n.contains("what do you do"):
		return "I'm Filo, a little wiki guide for any game. Ask me about bosses, items or quests."
	if n.contains("how are you") or n.contains("how's it going") or n.contains("how is it going"):
		return "Doing great, thanks! What are you playing?"
	if n.contains("hear me") or n.contains("test") or n.contains("there") or n.contains("listening"):
		return "Loud and clear!"
	return "Hey! Ask me anything about your game."


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
		"route": "local",
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


func user_content(question: String, passages: Array, rewrite: Dictionary = {}, game_name: String = "") -> String:
	var game := game_name if game_name != "" else (profile.name if profile else "unknown")
	var parts := ["Game: " + game]
	var ctx := session.context()
	ctx.merge(session_context, true)
	if ctx.is_empty():
		parts.append("Session context: none")
	else:
		parts.append("Session context: " + JSON.stringify(ctx))
	if not history.is_empty():
		var turns := PackedStringArray()
		for h in history:
			turns.append("Player: %s\nFilo: %s" % [str(h.q), str(h.a).left(200)])
		parts.append("Recent conversation:\n" + "\n".join(turns))
	if passages.is_empty():
		parts.append("Notes: none matched this question.")
	else:
		parts.append("Notes:")
		for i in passages.size():
			var ch: Dictionary = passages[i].chunk
			var label := "Wikipedia: " if str(ch.get("kind", "kb")) == "web" else ""
			parts.append("[%d] %s%s — %s\n%s" % [i + 1, label, ch.title, ch.source, ch.text])
	if not rewrite.is_empty() and str(rewrite.get("wiki", "")) != "":
		parts.append("Suggested wiki search: \"%s\"%s" % [rewrite.wiki, " (a follow-up about: %s)" % session.last_topic() if rewrite.get("followup", false) else ""])
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
