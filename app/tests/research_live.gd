extends SceneTree
## Live checks against the real NVIDIA NIM API and real wikis. DO NOT RUN THIS DIRECTLY: it is started by
## scripts/bench_live.py, which requires NVIDIA_API_KEY in the environment, caps the run at 20 requests and
## 30 requests/minute (FILO_NIM_MAX_REQUESTS / FILO_NIM_MAX_RPM, enforced inside NimClient) and never prints
## the key. Without FILO_LIVE_VIA_BENCH=1 this script refuses to make a single live request.
##
##   --smoke   every configured model is listed by /v1/models and at least one returns a tool call for
##             "Where do I find the Shinobi Firecracker in Sekiro?"
##   --bench   the 8 benchmark questions of tests/golden_questions.json (2 per game) through the full research
##             agent; prints a table and writes --json PATH with p50/p95 latency and key-term accuracy
##   --models a,b  --no-prefetch  --no-stream  --limit N  --label TEXT

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_environment("FILO_LIVE_VIA_BENCH") != "1":
		print("REFUSED: live requests are only allowed through scripts/bench_live.py")
		quit(2)
		return
	var raw := OS.get_cmdline_user_args()
	var args := FiloArgs.parse(raw)
	var cfg := FiloConfig.load_default(args)
	FiloLog.verbose = args.has("verbose")
	if str(cfg.get_value("nvidia_api_key", "")) == "":
		print("SKIPPED: no NVIDIA_API_KEY")
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
	var mi := raw.find("--models")
	if mi >= 0 and mi + 1 < raw.size():
		agent.models = ResearchAgent.normalize_models(Array(raw[mi + 1].split(",", false)))
	if "--no-prefetch" in raw:
		agent.prefetch = false
	if "--no-stream" in raw:
		agent.stream = false
	var profile := GameProfile.load_from(FiloConfig.project_root().path_join("profiles"), "sekiro")
	agent.set_profile(profile)
	agent.claude_fallback = false   # measure NIM only; nothing else may be called
	print("chain: %s | prefetch=%s stream=%s | request budget %d, %d/min" % [agent.chain_label(), agent.prefetch, agent.stream, nim.limiter.budget, nim.limiter.max_per_minute])
	if "--bench" in raw:
		await _bench(agent, nim, raw)
	else:
		await _smoke(nim, agent)
	print("\nlive checks: %s (%d NIM requests)" % ["FAILED" if failures > 0 else "passed", nim.requests_made])
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
		var resp: Dictionary = await nim.chat(m.id, msgs, ResearchAgent.tool_schemas(agent.wiki_names()), {"timeout": 30.0, "max_tokens": 200, "tool_choice": "required", "extra_body": agent._extra_for(m)})
		var calls := ResearchAgent.tool_calls_of(resp.message) if resp.ok else []
		var names := []
		for c in calls:
			names.append(str(c.get("function", {}).get("name", "")))
		var good: bool = resp.ok and not calls.is_empty()
		print("   tool_choice=required: status %d, %d ms, tool_calls=%s %s" % [int(resp.status), int(resp.latency_ms), str(names), "OK" if good else "(rejected or ignored: %s)" % str(resp.error)])
		any_working = any_working or good
	if not any_working:
		failures += 1
		print("FAIL: no model in the chain returned a tool call")


func _bench(agent: ResearchAgent, nim: NimClient, raw: PackedStringArray) -> void:
	var golden = JSON.parse_string(FileAccess.get_file_as_string(FiloConfig.project_root().path_join("tests/golden_questions.json")))
	var qs := []
	for q in golden.questions:
		if q.get("bench", false):
			qs.append(q)
	var li := raw.find("--limit")
	if li >= 0 and li + 1 < raw.size():
		qs = qs.slice(0, maxi(1, int(raw[li + 1])))
	var rows := []
	for q in qs:
		if nim.limiter.budget_left() <= 4:
			print("stopping early: the request budget for this run is nearly used up")
			break
		var rw := QueryRouter.rewrite(str(q.question), str(q.game))
		var hints := {"force_tool": true, "wiki_query": rw.wiki, "web_query": rw.web, "game": q.game, "tag": str(q.id)}
		var content := "Game: %s\n\nSuggested wiki search: \"%s\"\n\nQuestion: %s" % [q.game, rw.wiki, q.question]
		var r: Dictionary = await agent.answer(content, str(q.game), hints)
		var answer := str(r.text).to_lower()
		var hit := 0
		for group in q.expect:
			for alt in group:
				if answer.contains(str(alt).to_lower()):
					hit += 1
					break
		var acc := float(hit) / float(q.expect.size())
		rows.append({"id": q.id, "game": q.game, "question": q.question, "ok": r.ok, "model": r.model, "rounds": r.rounds, "tool_calls": r.tool_calls,
			"first_response_ms": r.first_response_ms, "model_ms": r.model_ms, "tool_ms": r.tool_ms, "total_ms": r.total_ms, "accuracy": acc, "answer": str(r.text).left(200)})
		print("  %-3s %-52s %s %5d ms (first %d ms, %d rounds, %d tools) accuracy %.2f" % [q.id, str(q.question).left(52), "ok " if r.ok else "ERR", r.total_ms, r.first_response_ms, r.rounds, r.tool_calls, acc])
	var totals := []
	var firsts := []
	var acc_sum := 0.0
	var ok_n := 0
	for row in rows:
		if row.ok:
			ok_n += 1
			totals.append(row.total_ms)
			if int(row.first_response_ms) >= 0:
				firsts.append(row.first_response_ms)
		acc_sum += float(row.accuracy)
	var summary := {"questions": rows.size(), "answered": ok_n, "total_ms_p50": _pct(totals, 0.5), "total_ms_p95": _pct(totals, 0.95),
		"first_response_ms_p50": _pct(firsts, 0.5), "first_response_ms_p95": _pct(firsts, 0.95),
		"keyword_accuracy": acc_sum / maxf(1.0, float(rows.size())), "nim_requests": nim.requests_made}
	print("\nsummary: ", JSON.stringify(summary))
	if summary.answered == 0:
		failures += 1
	var out_path := ""
	var oi := raw.find("--json")
	if oi >= 0 and oi + 1 < raw.size():
		out_path = raw[oi + 1]
	if out_path != "":
		var label := "run"
		var lbi := raw.find("--label")
		if lbi >= 0 and lbi + 1 < raw.size():
			label = raw[lbi + 1]
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"label": label, "date": Time.get_datetime_string_from_system(), "config": {"prefetch": agent.prefetch, "stream": agent.stream, "models": agent.chain_label()}, "summary": summary, "rows": rows}, "  "))
			print("wrote ", out_path)


## Nearest-rank percentile of a list of numbers (-1 when empty).
static func _pct(values: Array, p: float) -> int:
	if values.is_empty():
		return -1
	var v := values.duplicate()
	v.sort()
	return int(v[clampi(int(ceil(p * v.size())) - 1, 0, v.size() - 1)])
