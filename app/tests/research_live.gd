extends SceneTree
## Live checks against the real NVIDIA NIM API and real wikis. Needs NVIDIA_API_KEY (env or .env);
## prints SKIPPED and exits 0 without one.
##
##   smoke (default): every configured model is listed by /v1/models, and at least one working
##                    model answers "Where do I find the Shinobi Firecracker in Sekiro?" with a
##                    wiki_search/web_search tool call.
##   --bench:         runs sample questions from Sekiro, Dark Souls and Crimson Desert through the
##                    full agent loop and prints a latency table.
##   --models a,b:    override the model chain for this run (compare models one at a time).
##
## godot --headless --path app -s tests/research_live.gd -- [--bench] [--models id1,id2]

const QUESTIONS := [
	["Sekiro: Shadows Die Twice", "Where do I find the Shinobi Firecracker in Sekiro?"],
	["Sekiro: Shadows Die Twice", "How do I beat Lady Butterfly in Sekiro?"],
	["Dark Souls", "Where do I find the Lordvessel in Dark Souls?"],
	["Dark Souls", "How do I avoid locking myself out of Siegmeyer's questline in Dark Souls?"],
	["Crimson Desert", "Who is Kliff in Crimson Desert?"],
	["Crimson Desert", "What is Oongka's role in Crimson Desert?"],
]

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := FiloArgs.parse(OS.get_cmdline_user_args())
	var cfg := FiloConfig.load_default(args)
	FiloLog.verbose = args.has("verbose")
	if str(cfg.get_value("nvidia_api_key", "")) == "":
		print("SKIPPED: no NVIDIA_API_KEY (set it in the environment or .env to run the live checks)")
		quit(0)
		return
	var nim := NimClient.new()
	var claude := ClaudeClient.new()
	var wiki := WikipediaClient.new()
	var tools := WebTools.new()
	var agent := ResearchAgent.new()
	for n in [nim, claude, wiki, tools, agent]:
		root.add_child(n)
	nim.configure(cfg)
	claude.configure(cfg)
	wiki.configure(cfg)
	tools.configure(cfg, wiki)
	agent.setup(cfg, nim, claude, wiki, tools)
	var raw := OS.get_cmdline_user_args()
	var mi := raw.find("--models")
	if mi >= 0 and mi + 1 < raw.size():
		agent.models = ResearchAgent.normalize_models(Array(raw[mi + 1].split(",", false)))
	var profile := GameProfile.load_from(FiloConfig.project_root().path_join("profiles"), "sekiro")
	agent.set_profile(profile)
	agent.claude_fallback = false   # measure NIM only
	print("chain: ", agent.chain_label())
	if ("--bench" in OS.get_cmdline_user_args()):
		await _bench(agent)
	else:
		await _smoke(nim, agent)
	print("\nlive checks: %s" % ("FAILED" if failures > 0 else "passed"))
	quit(1 if failures > 0 else 0)


func _smoke(nim: NimClient, agent: ResearchAgent) -> void:
	var listing: Dictionary = await nim.list_models()
	print("listed %d models" % listing.ids.size() if listing.ok else "model list failed: %s" % listing.error)
	var any_working := false
	for m in agent.models:
		var listed: bool = listing.ok and listing.ids.has(m.id)
		print("%-42s listed=%s" % [m.id, str(listed)])
		if not listed:
			continue
		var msgs := [
			{"role": "system", "content": agent.system_prompt("Sekiro: Shadows Die Twice", true)},
			{"role": "user", "content": "Where do I find the Shinobi Firecracker in Sekiro?"},
		]
		var resp: Dictionary = await nim.chat(m.id, msgs, ResearchAgent.tool_schemas(agent.wiki_names()), {"timeout": 30.0, "max_tokens": 200, "extra_body": agent._extra_for(m)})
		var calls := ResearchAgent.tool_calls_of(resp.message) if resp.ok else []
		var names := []
		for c in calls:
			names.append(str(c.get("function", {}).get("name", "")))
		var good: bool = resp.ok and not calls.is_empty() and (names[0] == "wiki_search" or names[0] == "web_search")
		print("   chat %d ms status=%d tool_calls=%s %s" % [int(resp.latency_ms), int(resp.status), str(names), "OK" if good else "(no usable tool call: %s)" % str(resp.error)])
		any_working = any_working or good
	if not any_working:
		failures += 1
		print("FAIL: no model in the chain returned a wiki_search/web_search tool call")


func _bench(agent: ResearchAgent) -> void:
	var rows := []
	for q in QUESTIONS:
		var r: Dictionary = await agent.answer("Game: %s\n\nQuestion: %s" % [q[0], q[1]], q[0])
		rows.append({"game": q[0], "q": q[1], "r": r})
		print("  %s -> %s" % [q[1], ("'%s'" % r.text.left(110)) if r.ok else "FAILED: " + str(r.error)])
	print("\n| game | question | model | rounds | tools | first response | tools | total | ok |")
	print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	var totals := []
	for row in rows:
		var r: Dictionary = row.r
		print("| %s | %s | %s | %d | %d | %d ms | %d ms | %d ms | %s |" % [row.game.get_slice(":", 0), row.q.left(48), str(r.model).split("/")[-1] if str(r.model) != "" else "-", r.rounds, r.tool_calls, r.first_response_ms, r.tool_ms, r.total_ms, "yes" if r.ok else "NO"])
		if r.ok:
			totals.append(r.total_ms)
	if totals.is_empty():
		failures += 1
		return
	totals.sort()
	print("\nsuccessful answers: %d/%d, median total %d ms, slowest %d ms" % [totals.size(), rows.size(), totals[totals.size() / 2], totals[-1]])
