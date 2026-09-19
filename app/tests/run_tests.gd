extends SceneTree
## Headless unit tests: godot --headless --path app -s tests/run_tests.gd

var failures := 0
var passes := 0


func _init() -> void:
	_test_easing()
	_test_mesh()
	_test_args()
	_test_config()
	_test_note_parsing()
	_test_retriever()
	_test_sources_parsing()
	_test_speech_cleanup()
	_test_request_body()
	_test_face_sprites()
	_test_bubble_sources()
	_test_dotenv_and_providers()
	_test_nim_client()
	_test_wikipedia()
	_test_pipeline_prompting()
	_test_speaker()
	_test_mascot_face_stability()
	_test_bubble_controls()
	print("\n%d passed, %d failed" % [passes, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		failures += 1
		printerr("FAIL: " + msg)
		print("FAIL: " + msg)


func _test_easing() -> void:
	check(is_equal_approx(Easing.out_back(0.0), 0.0), "out_back(0) == 0")
	check(is_equal_approx(Easing.out_back(1.0), 1.0), "out_back(1) == 1")
	var peak := 0.0
	for i in 101:
		peak = maxf(peak, Easing.out_back(i / 100.0, 1.55))
	check(peak > 1.02 and peak < 1.2, "out_back overshoots slightly (peak %.3f)" % peak)
	check(Easing.in_sine(0.5) < 0.5, "in_sine starts slow")
	check(Easing.out_sine(0.5) > 0.5, "out_sine starts fast")


func _test_mesh() -> void:
	var mesh := RoundedBoxMesh.build(1.0, 0.18, 8)
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check(verts.size() == 6 * 9 * 9, "vertex count %d" % verts.size())
	check(indices.size() == 6 * 8 * 8 * 6, "index count %d" % indices.size())
	var max_r := 0.0
	var unit_ok := true
	for i in verts.size():
		max_r = maxf(max_r, verts[i].length())
		if not is_equal_approx(normals[i].length(), 1.0):
			unit_ok = false
	check(unit_ok, "all normals are unit length")
	check(max_r < 0.5 * sqrt(3.0), "corners are rounded (max radius %.3f < %.3f)" % [max_r, 0.5 * sqrt(3.0)])
	var inside := true
	for v in verts:
		if absf(v.x) > 0.5001 or absf(v.y) > 0.5001 or absf(v.z) > 0.5001:
			inside = false
	check(inside, "mesh stays inside the unit cube")
	# Godot front faces wind clockwise seen from outside: (b-a)x(c-a) points inward.
	var cw := 0
	var ccw := 0
	for t in range(0, indices.size(), 3):
		var a := verts[indices[t]]
		var b := verts[indices[t + 1]]
		var c := verts[indices[t + 2]]
		var n := (b - a).cross(c - a)
		var centroid := (a + b + c) / 3.0
		if n.dot(centroid) < 0.0:
			cw += 1
		else:
			ccw += 1
	check(ccw == 0, "all %d triangles wind clockwise (found %d counter-clockwise)" % [cw + ccw, ccw])


func _test_args() -> void:
	var a := FiloArgs.parse(PackedStringArray(["--showcase", "--ask", "how do I beat him", "--quit-after", "12", "--mute", "--capture-dir=/tmp/x"]))
	check(a.get("showcase") == true, "flag parsed")
	check(a.get("ask") == "how do I beat him", "value parsed")
	check(a.get("quit_after") == "12", "dashes become underscores")
	check(a.get("mute") == true, "trailing flag parsed")
	check(a.get("capture_dir") == "/tmp/x", "key=value parsed")
	var sh := FiloArgs.split_shell("script.py --wake --followup 'what about its second phase' --q \"Who is Ganon?\" plain\\ word")
	check(sh.size() == 7 and sh[3] == "what about its second phase" and sh[5] == "Who is Ganon?" and sh[6] == "plain word", "shell-style splitting keeps quoted phrases: " + str(sh))
	check(FiloArgs.split_shell("").is_empty() and FiloArgs.split_shell("   ").is_empty(), "empty arg strings")


func _test_config() -> void:
	var base := {"a": 1, "nested": {"x": 1, "y": 2}}
	FiloConfig.merge_into(base, {"nested": {"y": 3, "z": 4}, "b": 2})
	check(base.nested.x == 1 and base.nested.y == 3 and base.nested.z == 4 and base.b == 2, "deep merge keeps and overrides")
	var cfg := FiloConfig.new()
	cfg.data = FiloConfig.DEFAULTS.duplicate(true)
	check(cfg.get_value("web_search.confidence_threshold", 0.0) == 0.45, "dotted lookup")
	check(cfg.get_value("nope.nothing", "dflt") == "dflt", "dotted lookup default")
	cfg.apply_args({"mute": true, "profile": "demo"})
	check(cfg.get_value("tts.enabled") == false and cfg.get_value("default_profile") == "demo", "args override config")
	check(cfg.hotkey_label() == "⌥ Space", "hotkey label: " + cfg.hotkey_label())
	check(FiloConfig.project_root().ends_with("Filo"), "project root is the repo root: " + FiloConfig.project_root())


func _test_note_parsing() -> void:
	var n := GameProfile.parse_note("# Guardian Ape\nsource: https://example.com/ape\ntags: boss, sunken valley\n\nFirst paragraph: has a colon.\n\nSecond paragraph.\n", "guardian_ape.md")
	check(n.title == "Guardian Ape", "note title")
	check(n.source == "https://example.com/ape", "note source")
	check(n.tags == "boss, sunken valley", "note tags")
	check(n.body.begins_with("First paragraph: has a colon.") and n.body.ends_with("Second paragraph."), "note body")
	var m := GameProfile.parse_note("Just a body.", "my_note.md")
	check(m.title == "My Note" and m.body == "Just a body.", "untitled note falls back to file name")


func _test_retriever() -> void:
	var dir := FiloConfig.project_root().path_join("profiles")
	var p := GameProfile.load_from(dir, "sekiro")
	check(p.load_error == "", "sekiro profile loads: " + p.load_error)
	check(p.notes.size() >= 5, "sekiro profile has sample notes (%d)" % p.notes.size())
	check(p.matches_app("sekiro") and not p.matches_app("Finder"), "app matching")
	var r := Retriever.new()
	r.build(p)
	check(r.chunks.size() >= p.notes.size(), "chunks built (%d)" % r.chunks.size())
	var res := r.search("I'm stuck on the Guardian Ape, what am I missing?")
	check(res.results.size() > 0 and str(res.results[0].chunk.title).to_lower().contains("guardian ape"), "guardian ape question retrieves the Guardian Ape note")
	check(res.confidence >= 0.6, "guardian ape confidence high (%.2f)" % res.confidence)
	var far := r.search("what is the fastest route to the demon of hatred")
	check(far.confidence < 0.45, "unknown boss question has low confidence (%.2f)" % far.confidence)
	var ogre := r.search("how do I deal with the chained ogre grabs")
	check(ogre.results.size() > 0 and str(ogre.results[0].chunk.title).to_lower().contains("ogre"), "ogre question retrieves the Chained Ogre note")
	check(Retriever.stem("firecrackers") == "firecracker" and Retriever.stem("illusions") == "illusion", "stemmer")
	var chunks := Retriever.split_chunks("para one\n\npara two\n\npara three")
	check(chunks.size() == 1, "short paragraphs merge into one chunk")


func _test_sources_parsing() -> void:
	var s := AnswerPipeline.split_sources("Use firecrackers.\nThen run.\nSOURCES: 1, 3")
	check(s.text == "Use firecrackers.\nThen run.", "sources line stripped: " + s.text)
	check(s.indices == [1, 3], "indices parsed: " + str(s.indices))
	var none := AnswerPipeline.split_sources("Nothing here.\nSources: none")
	check(none.text == "Nothing here." and none.indices.is_empty(), "sources none")
	var plain := AnswerPipeline.split_sources("Just text.")
	check(plain.text == "Just text." and plain.indices.is_empty(), "no sources line")
	var inline := AnswerPipeline.split_sources("Dash back to avoid the grab. SOURCES: 1, 3")
	check(inline.text == "Dash back to avoid the grab." and inline.indices == [1, 3], "inline sources marker stripped: " + inline.text)
	var lower := AnswerPipeline.split_sources("Use fire.\n\nSources: none")
	check(lower.text == "Use fire." and lower.indices.is_empty(), "lower-case sources none")


func _test_speech_cleanup() -> void:
	check(AnswerPipeline.clean_for_speech("Use **firecrackers** and `run` [wiki](http://x) now.") == "Use firecrackers and run wiki now.", "markdown stripped")


func _test_request_body() -> void:
	var c := ClaudeClient.new()
	c.api_key = "k"
	c.model = "claude-opus-5"
	c.effort = "low"
	var body := c.build_request("sys", [{"role": "user", "content": "hi"}], [{"type": "web_search_20260209", "name": "web_search", "max_uses": 2}])
	check(body.model == "claude-opus-5" and body.system == "sys", "request basics")
	check(body.output_config.effort == "low", "effort included")
	check(body.fallbacks == "default", "refusal fallbacks opted in")
	check(body.tools.size() == 1 and body.tools[0].type == "web_search_20260209", "web search tool attached")
	var headers := c.build_headers()
	check("anthropic-beta: server-side-fallback-2026-07-01" in headers and "anthropic-version: 2023-06-01" in headers, "headers")
	c.model = "claude-haiku-4-5"
	var b2 := c.build_request("sys", [], [])
	check(not b2.has("output_config") and not b2.has("tools"), "haiku gets no effort; no tools when none requested")
	c.free()


func _test_face_sprites() -> void:
	check(FaceSprites.name_for_state(MascotAnimator.State.THINKING) == "thinking", "state -> sprite name")
	var s := FaceSprites.get_sprite("listening")
	check(s.eye_size.x > FaceSprites.get_sprite("idle").eye_size.x, "listening eyes are wider")
	check(FaceSprites.get_sprite("thinking").eye_open < 1.0 and FaceSprites.get_sprite("thinking").eye_shift.y > 0.0, "thinking eyes narrowed and glancing up")
	check(FaceSprites.get_sprite("asleep").eye_open == 0.0, "asleep eyes closed")
	s.eye_open = 0.0
	check(FaceSprites.get_sprite("listening").eye_open == 1.0, "get_sprite returns copies")


func _test_bubble_sources() -> void:
	var t := Bubble.format_sources([{"kind": "kb", "title": "Guardian Ape", "url": "x"}, {"kind": "web", "title": "Page", "url": "https://example.com/a/b"}], true)
	check(t.contains("notes: Guardian Ape") and t.contains("web: Page") and t.contains("example.com"), "sources formatted: " + t)
	check(Bubble.format_sources([], true) == "◆ searched the web", "web-only footer")
	check(Bubble.format_sources([], false) == "", "empty footer")


func _test_dotenv_and_providers() -> void:
	var env := FiloConfig.parse_dotenv("# comment\nANTHROPIC_API_KEY=sk-ant-abcdefghijklmnopqrstuvwxyz\nexport NVIDIA_API_KEY=\"nvapi-xyz-1234567890\"\nFILO_PROVIDER=nim # trailing comment\nBROKEN\n")
	check(env.get("ANTHROPIC_API_KEY") == "sk-ant-abcdefghijklmnopqrstuvwxyz", "dotenv plain value")
	check(env.get("NVIDIA_API_KEY") == "nvapi-xyz-1234567890", "dotenv export + quotes")
	check(env.get("FILO_PROVIDER") == "nim", "dotenv trailing comment stripped")
	check(not env.has("BROKEN"), "dotenv ignores lines without =")
	var cfg := FiloConfig.new()
	cfg.data = FiloConfig.DEFAULTS.duplicate(true)
	cfg.data["anthropic_api_key"] = "sk-ant-..."
	cfg.normalize_keys()
	check(cfg.get_value("anthropic_api_key") == "" and cfg.provider() == "none", "placeholder key is ignored -> none")
	cfg.data["anthropic_api_key"] = "nvapi-abcdefghijklmnopqrstuvwxyz0123456789"
	cfg.normalize_keys()
	check(cfg.get_value("anthropic_api_key") == "" and cfg.get_value("nvidia_api_key").begins_with("nvapi-"), "nvapi key under ANTHROPIC_API_KEY moves to nvidia_api_key")
	check(cfg.provider() == "nim", "auto provider picks nim when only the NVIDIA key exists")
	cfg.data["anthropic_api_key"] = "sk-ant-abcdefghijklmnopqrstuvwxyz"
	cfg.normalize_keys()
	check(cfg.provider() == "anthropic", "auto provider prefers anthropic when both keys exist")
	cfg.data["llm"]["provider"] = "nim"
	check(cfg.provider() == "nim", "explicit provider respected")
	cfg.data["llm"]["provider"] = "anthropic"
	cfg.data["anthropic_api_key"] = ""
	check(cfg.provider() == "none", "explicit provider without a key -> none")
	check(int(FiloConfig.DEFAULTS["mascot"]["size"]) == 200, "cube default size is 200pt")
	check(bool(FiloConfig.DEFAULTS["wake_word"]["enabled"]), "wake word on by default")


func _test_nim_client() -> void:
	var c := NimClient.new()
	c.api_key = "nvapi-test"
	c.model = "nvidia/nemotron-3-super-120b-a12b"
	var body := c.build_request("sys", "hello")
	check(body.model == "nvidia/nemotron-3-super-120b-a12b" and body.messages.size() == 2 and body.messages[0].role == "system" and body.stream == false, "nim request body")
	check(body.chat_template_kwargs.enable_thinking == false, "nim reasoning switched off by default")
	c.reasoning = true
	check(not c.build_request("s", "u").has("chat_template_kwargs"), "nim reasoning can be re-enabled")
	check("Authorization: Bearer nvapi-test" in c.build_headers(), "nim auth header")
	check(NimClient.strip_thinking("<think>hmm\nmore</think>\nAnswer here.") == "Answer here.", "think tags stripped")
	check(NimClient.strip_thinking("plain answer") == "plain answer", "plain text untouched")
	check(FaceSprites.get_sprite("pleased").eye_style == 1 and FaceSprites.get_sprite("pleased").mouth_style == 1, "pleased sprite uses happy arches and the w mouth")
	c.free()


func _test_wikipedia() -> void:
	var w := WikipediaClient.new()
	check(WikipediaClient.build_search_query("who is ganon", "The Legend of Zelda") == "The Legend of Zelda who is ganon", "search query biased with the game name")
	check(WikipediaClient.build_search_query("who is ganon", "") == "who is ganon", "search query without game")
	check(w.search_url("who is ganon?", 2).contains("srsearch=who%20is%20ganon%3F") and w.search_url("x", 2).contains("srlimit=2"), "search url: " + w.search_url("who is ganon?", 2))
	check(w.summary_url("The Legend of Zelda").ends_with("/api/rest_v1/page/summary/The_Legend_of_Zelda"), "summary url: " + w.summary_url("The Legend of Zelda"))
	check("User-Agent: Filo/0.1 (game overlay companion; local use)" in w.build_headers(), "user agent header")
	var titles := WikipediaClient.parse_search({"query": {"search": [{"title": "Ganon", "pageid": 1}, {"title": "The Legend of Zelda"}]}})
	check(titles.size() == 2 and titles[0] == "Ganon", "search parsing")
	check(WikipediaClient.parse_search({"error": "x"}).is_empty(), "search parsing tolerates errors")
	var std := WikipediaClient.parse_summary({"type": "standard", "title": "Ganon", "extract": "Ganon is the antagonist.", "content_urls": {"desktop": {"page": "https://en.wikipedia.org/wiki/Ganon"}}})
	check(std.title == "Ganon" and std.url == "https://en.wikipedia.org/wiki/Ganon" and std.text == "Ganon is the antagonist." and std.source == std.url, "summary parsing")
	check(WikipediaClient.parse_summary({"type": "disambiguation", "title": "X", "extract": "may refer to"}).is_empty(), "disambiguation skipped")
	check(WikipediaClient.parse_summary({"type": "standard", "title": "Empty"}).is_empty(), "missing extract skipped")
	check(WikipediaClient.parse_summary({"type": "standard", "title": "D", "description": "only a description", "canonicalurl": "https://en.wikipedia.org/wiki/D"}).text == "only a description", "description fallback + canonicalurl")
	w.free()


func _test_pipeline_prompting() -> void:
	var p := AnswerPipeline.new()
	var prof := GameProfile.new()
	prof.name = "Sekiro: Shadows Die Twice"
	p.profile = prof
	p.max_history = 4
	var passages := [
		{"chunk": {"title": "Guardian Ape", "source": "https://notes/ape", "text": "Firecrackers stagger it."}, "score": 3.0},
		{"chunk": {"title": "Ganon", "source": "https://en.wikipedia.org/wiki/Ganon", "text": "Ganon is the antagonist.", "kind": "web"}, "score": 0.0},
	]
	var user := p.user_content("who is ganon", passages)
	check(user.contains("[1] Guardian Ape — https://notes/ape") and user.contains("[2] Wikipedia: Ganon — https://en.wikipedia.org/wiki/Ganon"), "wiki passages are numbered after the notes")
	check(not user.contains("Recent conversation"), "no history section when empty")
	p._remember("first question", "first answer")
	user = p.user_content("and the second phase?", passages)
	check(user.contains("Recent conversation:\nPlayer: first question\nFilo: first answer"), "history included for follow-ups")
	for i in 6:
		p._remember("q%d" % i, "a%d" % i)
	check(p.history.size() == 4 and p.history[0].q == "q2", "history trimmed to conversation_turns")
	var sys := p.system_prompt(false, true)
	check(sys.contains("Wikipedia") and sys.contains("follow-up") and sys.contains("SOURCES:"), "system prompt mentions wikipedia, follow-ups and sources")
	p.cfg = FiloConfig.new()
	p.cfg.data = FiloConfig.DEFAULTS.duplicate(true)
	p.provider = "nim"
	check(p.web_provider() == "wikipedia", "auto web provider is wikipedia for nim")
	p.provider = "anthropic"
	check(p.web_provider() == "anthropic", "auto web provider is claude search for anthropic")
	p.cfg.data["web_search"]["provider"] = "wikipedia"
	check(p.web_provider() == "wikipedia", "explicit wikipedia provider")
	p.cfg.data["web_search"]["enabled"] = false
	check(p.web_provider() == "off", "web search disabled")
	p.free()


static func _write_ascii(buf: PackedByteArray, offset: int, text: String) -> void:
	var bytes := text.to_ascii_buffer()
	for i in bytes.size():
		buf.encode_u8(offset + i, bytes[i])


func _test_speaker() -> void:
	# A minimal, valid 16-bit mono PCM WAV: canonical 44-byte header + a short
	# sine-ish waveform. This is the exact shape Kokoro's /synthesize returns,
	# built by hand so the parser is tested without a network call.
	var rate := 24000
	var n := 480   # 20 ms
	var pcm := PackedByteArray()
	pcm.resize(n * 2)
	for i in n:
		var v := sin(TAU * 440.0 * float(i) / float(rate)) * 0.5
		pcm.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	# Written entirely with encode_*() at explicit offsets into a pre-sized
	# buffer — append_array() would grow past the reserved header instead of
	# filling it, which is exactly the bug this test exists to catch.
	var wav := PackedByteArray()
	wav.resize(44 + pcm.size())
	_write_ascii(wav, 0, "RIFF")
	wav.encode_u32(4, 36 + pcm.size())
	_write_ascii(wav, 8, "WAVE")
	_write_ascii(wav, 12, "fmt ")
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)          # PCM
	wav.encode_u16(22, 1)          # mono
	wav.encode_u32(24, rate)
	wav.encode_u32(28, rate * 2)   # byte rate
	wav.encode_u16(32, 2)          # block align
	wav.encode_u16(34, 16)         # bits per sample
	_write_ascii(wav, 36, "data")
	wav.encode_u32(40, pcm.size())
	for i in pcm.size():
		wav.encode_u8(44 + i, pcm[i])

	var parsed := Speaker._parse_wav(wav)
	check(not parsed.is_empty(), "Speaker parses a canonical 16-bit mono WAV")
	check(parsed.rate == rate, "parsed sample rate matches the fmt chunk (%d)" % parsed.get("rate", -1))
	check(is_equal_approx(parsed.duration, float(n) / float(rate)), "parsed duration matches sample count / rate (%.4f)" % parsed.get("duration", -1.0))
	check(parsed.data.size() == pcm.size(), "parsed PCM data is the full data chunk, untruncated")
	check(not parsed.envelope.is_empty(), "an RMS envelope is produced")
	for e in parsed.envelope:
		check(e >= 0.0 and e <= 1.0, "envelope values stay in 0..1")

	check(Speaker._parse_wav(PackedByteArray([1, 2, 3])).is_empty(), "garbage bytes parse to empty, not a crash")
	check(Speaker._parse_wav(PackedByteArray()).is_empty(), "empty bytes parse to empty")
	var not_riff := wav.duplicate()
	not_riff[0] = 88
	check(Speaker._parse_wav(not_riff).is_empty(), "a non-RIFF header is rejected")

	var starts := Speaker._compute_word_starts("Use the Shinobi Firecracker, then hit it.")
	check(starts.size() == 7, "word count matches (%d)" % starts.size())
	check(starts[0] == 0, "first word starts at 0")
	check(starts[1] == 4, "second word offset is correct (%d)" % starts[1])
	check(Speaker._compute_word_starts("").is_empty(), "empty text has no words")
	check(Speaker._compute_word_starts("one").size() == 1, "a single word still gets one offset")

	var s := Speaker.new()
	check(s.force_finish.is_valid(), "Speaker exposes a force_finish() safety valve")
	s.free()


func _test_mascot_face_stability() -> void:
	# Regression test for the "stuck with one eye closed" bug: eye_asym used
	# to be defined only on the "wink" sprite, so once a wink fired the
	# per-frame lerp (which only ever visits keys present in face_target) had
	# nothing to ease it back with. Every sprite must carry every BASE key.
	for sprite_name in FaceSprites.OVERRIDES.keys():
		var sprite := FaceSprites.get_sprite(sprite_name)
		for key in FaceSprites.BASE.keys():
			check(sprite.has(key), "sprite '%s' carries the '%s' key" % [sprite_name, key])
	check("idle" in FaceSprites.IDLE_MOODS, "the classic idle look stays in the mood roster")
	check(FaceSprites.IDLE_MOODS.size() >= 4, "several idle moods exist for variety (%d)" % FaceSprites.IDLE_MOODS.size())

	var a := MascotAnimator.new()
	a.face = FaceSprites.get_sprite("wink")
	a.face_target = FaceSprites.get_sprite("wink")
	for i in 40:
		a._process(0.05)
	var stuck_eye: float = a.face.eye_asym.y
	check(stuck_eye < 0.05, "wink actually closes the right eye (asym.y=%.2f)" % stuck_eye)
	a.face_target = FaceSprites.get_sprite("idle")
	for i in 60:
		a._process(0.05)
	var recovered_eye: float = a.face.eye_asym.y
	check(recovered_eye > 0.95, "the eye fully reopens once the target moves off wink (asym.y=%.2f) — this is exactly the bug that got fixed" % recovered_eye)

	# The mood roster must actually cycle away from — and back to — idle over
	# a run of turns, and never silently stop varying.
	var b := MascotAnimator.new()
	b._set_state(MascotAnimator.State.IDLE)
	var seen := {}
	for i in 30:
		b.register_turn()
		seen[b._mood] = true
	check(seen.size() >= 3, "mood rotation actually visits several different moods over 30 turns (%d seen)" % seen.size())
	check(seen.has("idle"), "idle keeps coming back into rotation, not excluded (seen: %s)" % str(seen.keys()))
	a.free()
	b.free()


func _test_bubble_controls() -> void:
	# Speaker: the mute button's runtime flag must silence output regardless
	# of the persisted `enabled` config, and be reversible.
	var sp := Speaker.new()
	sp.enabled = true
	sp.available = false          # no system voice in this headless test
	sp.kokoro_ready = false
	check(sp.active_provider() == "simulated", "unmuted with no real voice available falls back to simulated")
	sp.set_muted(true)
	check(sp.active_provider() == "muted", "set_muted(true) silences output even though enabled=true")
	sp.set_muted(false)
	check(sp.active_provider() == "simulated", "set_muted(false) restores normal output")
	sp.enabled = false
	sp.set_muted(false)
	check(sp.active_provider() == "muted", "a muted config (enabled=false) stays muted even if the button was never pressed")
	sp.free()

	# SoundToggle / ModeToggle: pure state + tooltip, no drawing needed to check.
	var sound := SoundToggle.new()
	sound._ready()
	check(not sound.muted and sound.tooltip_text == "Mute voice", "sound button starts unmuted with the right tooltip")
	sound.set_muted(true)
	check(sound.muted and sound.tooltip_text == "Unmute voice", "sound button reflects muted state")
	sound.set_muted(true)
	check(sound.muted, "setting the same state twice is a harmless no-op")
	sound.free()

	var mode := ModeToggle.new()
	mode._ready()
	check(mode.mode == "voice" and not mode.visible, "mode button starts in voice mode and hidden until the first answer")
	mode.set_mode("text")
	check(mode.mode == "text" and mode.tooltip_text == "Switch to talking", "mode button reflects text mode")
	mode.set_mode("voice")
	check(mode.mode == "voice" and mode.tooltip_text == "Switch to typing", "mode button switches back to voice")
	mode.free()

	# The click-region polygon: a valid 4-point loop tracing the rect's corners,
	# in the same order Window.mouse_passthrough_polygon expects.
	var main_script := load("res://main.gd")
	var rect := Rect2(12.0, 34.0, 56.0, 20.0)
	var poly: PackedVector2Array = main_script.rect_to_polygon(rect)
	check(poly.size() == 4, "the click region is a 4-point polygon")
	check(poly[0] == rect.position and poly[2] == rect.end, "opposite corners of the polygon match the rect's corners")
	for pt in poly:
		check(rect.has_point(pt) or is_equal_approx(pt.x, rect.position.x) or is_equal_approx(pt.x, rect.end.x), "every polygon point sits on the rect's boundary")
