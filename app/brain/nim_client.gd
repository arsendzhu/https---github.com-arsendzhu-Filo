class_name NimClient
extends Node
## OpenAI-compatible chat completions against NVIDIA NIM (integrate.api.nvidia.com).
## Same result shape as ClaudeClient.ask() so the pipeline can swap providers.
## NIM has no server-side web search, so web fallback is Anthropic-only.

var api_key := ""
var base_url := "https://integrate.api.nvidia.com/v1"
var model := "nvidia/nemotron-3-super-120b-a12b"
var max_tokens := 500
var temperature := 0.4
var reasoning := false   # Nemotron 3 thinks by default; off = ~3 s spoken answers instead of ~8-16 s
var timeout_sec := 75.0
var last_request: Dictionary = {}
var use_keepalive := true            # one persistent HTTPS connection (see NimConnection) instead of one per request
var conn: NimConnection
var limiter := RateLimiter.new(35)
var requests_made := 0
var _prefix := ""


func configure(cfg: FiloConfig) -> void:
	api_key = str(cfg.get_value("nvidia_api_key", ""))
	base_url = str(cfg.get_value("nim.base_url", base_url)).trim_suffix("/")
	model = str(cfg.get_value("nim.model", model))
	max_tokens = int(cfg.get_value("nim.max_tokens", max_tokens))
	temperature = float(cfg.get_value("nim.temperature", temperature))
	reasoning = bool(cfg.get_value("nim.reasoning", false))
	use_keepalive = bool(cfg.get_value("nim.keepalive", true))
	limiter.max_per_minute = int(cfg.get_value("nim.max_requests_per_minute", 35))
	# Hard caps set by the live benchmark (scripts/bench_live.py) so it can never exceed its allowance.
	var env_budget := OS.get_environment("FILO_NIM_MAX_REQUESTS")
	if env_budget != "":
		limiter.budget = maxi(1, int(env_budget))
	var env_rpm := OS.get_environment("FILO_NIM_MAX_RPM")
	if env_rpm != "":
		limiter.max_per_minute = maxi(1, int(env_rpm))
	if conn != null:
		conn.close()
		conn = null


func has_key() -> bool:
	return api_key.strip_edges() != ""


func build_request(system_prompt: String, user_content: String) -> Dictionary:
	var body := {
		"model": model,
		"max_tokens": max_tokens,
		"temperature": temperature,
		"stream": false,
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": user_content},
		],
	}
	if not reasoning:
		# NIM chat-template switch honoured by the Nemotron 3 family; harmless elsewhere
		body["chat_template_kwargs"] = {"enable_thinking": false}
	return body


func build_headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
		"Authorization: Bearer " + api_key,
	])


func ask(system_prompt: String, user_content: String, _tools: Array = []) -> Dictionary:
	var out := {"ok": false, "text": "", "citations": [], "searched": [], "error": "", "model": model, "stop_reason": ""}
	if not has_key():
		out.error = "No NVIDIA API key configured."
		return out
	if not await limiter.acquire():
		out.error = "The NIM request budget for this run is used up."
		return out
	requests_made += 1
	var body := build_request(system_prompt, user_content)
	last_request = body
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	http.accept_gzip = true
	add_child(http)
	var started := Time.get_ticks_msec()
	var err := http.request(base_url + "/chat/completions", build_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		out.error = "Could not start the request (error %d)." % err
		return out
	var res: Array = await http.request_completed
	http.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	FiloLog.debug("NIM HTTP %d in %d ms (result %d)" % [code, Time.get_ticks_msec() - started, result])
	if result != HTTPRequest.RESULT_SUCCESS:
		out.error = ClaudeClient._result_error(result).replace("Claude", "NVIDIA NIM")
		return out
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if code != 200:
		out.error = _http_error(code, parsed)
		return out
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("choices")) != TYPE_ARRAY or parsed.choices.is_empty():
		out.error = "Unexpected response from NVIDIA NIM."
		return out
	var choice: Dictionary = parsed.choices[0]
	out.stop_reason = str(choice.get("finish_reason", ""))
	out.model = str(parsed.get("model", model))
	var message: Dictionary = choice.get("message", {})
	var content = message.get("content", "")
	var text := ""
	if typeof(content) == TYPE_STRING:
		text = content
	elif typeof(content) == TYPE_ARRAY:
		for part in content:
			if typeof(part) == TYPE_DICTIONARY and part.get("type", "") == "text":
				text += str(part.get("text", ""))
	out.text = strip_thinking(text)
	out.ok = out.text.strip_edges() != ""
	if not out.ok:
		out.error = "NVIDIA NIM returned an empty answer."
	return out


## GET /v1/models once. {ok, ids, error}
func list_models() -> Dictionary:
	var out := {"ok": false, "ids": PackedStringArray(), "error": ""}
	if not has_key():
		out.error = "No NVIDIA API key configured."
		return out
	if not await limiter.acquire():
		out.error = "request budget exhausted"
		return out
	requests_made += 1
	var code := 0
	var raw := PackedByteArray()
	if _keepalive_ok():
		var res: Dictionary = await _connection().request(HTTPClient.METHOD_GET, _prefix + "/models", build_headers(), "", {"timeout": 15.0})
		if not res.ok:
			out.error = "network error"
			return out
		code = int(res.status)
		raw = res.body
	else:
		var http := HTTPRequest.new()
		http.timeout = 15.0
		http.accept_gzip = true
		add_child(http)
		if http.request(base_url + "/models", build_headers(), HTTPClient.METHOD_GET) != OK:
			http.queue_free()
			out.error = "request failed to start"
			return out
		var r: Array = await http.request_completed
		http.queue_free()
		if r[0] != HTTPRequest.RESULT_SUCCESS:
			out.error = "network error"
			return out
		code = int(r[1])
		raw = r[3]
	if code != 200:
		out.error = "HTTP %d" % code
		return out
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("data")) == TYPE_ARRAY:
		for m in parsed.data:
			if typeof(m) == TYPE_DICTIONARY and m.has("id"):
				out.ids.append(str(m.id))
	out.ok = true
	return out


func _keepalive_ok() -> bool:
	return use_keepalive and is_inside_tree()


func _connection() -> NimConnection:
	if conn == null:
		conn = NimConnection.new(get_tree())
		_prefix = conn.configure(base_url)
	return conn


## One raw chat-completions round trip for the research agent's tool loop (the
## agent owns the message history, tool execution, retries and model chain).
## opts: max_tokens, temperature, timeout, tool_choice, extra_body (merged into the body), stream (bool: server-sent
## events; `on_text` gets every content delta), so the time to the first token is measured.
## Returns {ok, status, message, finish_reason, model, error, retry_after, latency_ms, ttft_ms, timed_out, reused}
## where `message` is the assistant message exactly as the API returned it.
func chat(model_id: String, messages: Array, tools: Array, opts: Dictionary = {}) -> Dictionary:
	var out := {"ok": false, "status": 0, "message": {}, "finish_reason": "", "model": model_id, "error": "", "retry_after": 0.0, "latency_ms": 0, "ttft_ms": -1, "timed_out": false, "reused": false}
	if not has_key():
		out.error = "No NVIDIA API key configured."
		out.status = 401
		return out
	if not await limiter.acquire():
		out.error = "The NIM request budget for this run is used up."
		out.status = 429
		return out
	requests_made += 1
	var streaming := bool(opts.get("stream", false))
	var body := build_chat_body(model_id, messages, tools, opts, max_tokens, temperature)
	if streaming:
		body["stream"] = true
	last_request = body
	if _keepalive_ok():
		return await _chat_keepalive(model_id, body, opts, out)
	var http := HTTPRequest.new()
	http.timeout = float(opts.get("timeout", timeout_sec))
	http.accept_gzip = true
	add_child(http)
	var started := Time.get_ticks_msec()
	var err := http.request(base_url + "/chat/completions", build_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		out.error = "Could not start the request (error %d)." % err
		return out
	var res: Array = await http.request_completed
	http.queue_free()
	out.latency_ms = Time.get_ticks_msec() - started
	var result: int = res[0]
	out.status = res[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		out.timed_out = result == HTTPRequest.RESULT_TIMEOUT
		out.error = ClaudeClient._result_error(result).replace("Claude", "NVIDIA NIM")
		return out
	for h in res[2]:
		var hs := str(h)
		if hs.to_lower().begins_with("retry-after:"):
			out.retry_after = maxf(0.0, float(hs.substr(12).strip_edges()))
	var raw_text := (res[3] as PackedByteArray).get_string_from_utf8()
	var parsed = _parse_body(raw_text, streaming)
	var checked := parse_chat_response(int(out.status), parsed)
	out.merge(checked, true)
	if not out.has("model") or str(out.model) == "":
		out.model = model_id
	return out


## The persistent-connection path (also the streaming one).
func _chat_keepalive(model_id: String, body: Dictionary, opts: Dictionary, out: Dictionary) -> Dictionary:
	var streaming := bool(body.get("stream", false))
	var acc: SseAccumulator = null
	var run := {"timeout": float(opts.get("timeout", timeout_sec))}
	if streaming:
		acc = SseAccumulator.new(opts.get("on_text", Callable()))
		run["on_chunk"] = func(b: PackedByteArray) -> void: acc.feed(b)
	var res: Dictionary = await _connection().request(HTTPClient.METHOD_POST, _prefix + "/chat/completions", build_headers(), JSON.stringify(body), run)
	out.latency_ms = int(res.latency_ms)
	out.reused = bool(res.reused)
	out.status = int(res.status)
	if not res.ok:
		out.timed_out = bool(res.timed_out)
		out.error = ClaudeClient._result_error(HTTPRequest.RESULT_TIMEOUT if res.timed_out else HTTPRequest.RESULT_CANT_CONNECT).replace("Claude", "NVIDIA NIM")
		FiloLog.debug("NIM %s: %s after %d ms" % [model_id, str(res.error), int(res.latency_ms)])
		return out
	for h in res.headers:
		var hs := str(h)
		if hs.to_lower().begins_with("retry-after:"):
			out.retry_after = maxf(0.0, float(hs.substr(12).strip_edges()))
	if streaming and int(res.status) == 200:
		acc.finish()
		out.ttft_ms = acc.first_delta_ms if acc.first_delta_ms >= 0 else int(res.ttfb_ms)
		if acc.error != "":
			out.error = "NVIDIA NIM error: " + acc.error
			return out
		out.message = acc.message()
		out.finish_reason = acc.finish_reason
		if acc.model != "":
			out.model = acc.model
		out.ok = true
	else:
		out.ttft_ms = int(res.ttfb_ms)
		var parsed = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
		var checked := parse_chat_response(int(out.status), parsed)
		out.merge(checked, true)
		if not out.has("model") or str(out.model) == "":
			out.model = model_id
	FiloLog.info("NIM %s: status %d, first token %d ms, total %d ms%s%s" % [out.model, int(out.status), int(out.ttft_ms), int(out.latency_ms), ", streamed" if streaming else "", ", reused connection" if out.reused else ", new connection"])
	return out


## A non-200 streaming reply is plain JSON; a 200 one is not parsed here.
static func _parse_body(raw_text: String, streaming: bool):
	if streaming and raw_text.strip_edges().begins_with("data:"):
		var acc := SseAccumulator.new()
		acc.feed(raw_text.to_utf8_buffer())
		acc.finish()
		return {"choices": [{"message": acc.message(), "finish_reason": acc.finish_reason}], "model": acc.model}
	return JSON.parse_string(raw_text)


## Request body for one tool-loop round trip (static so tests can inspect it).
static func build_chat_body(model_id: String, messages: Array, tools: Array, opts: Dictionary, default_max_tokens: int, default_temperature: float) -> Dictionary:
	var body := {
		"model": model_id,
		"messages": messages,
		"max_tokens": int(opts.get("max_tokens", default_max_tokens)),
		"temperature": float(opts.get("temperature", default_temperature)),
		"stream": false,
	}
	if not tools.is_empty():
		body["tools"] = tools
		body["tool_choice"] = str(opts.get("tool_choice", "auto"))
	var extra = opts.get("extra_body", {})
	if typeof(extra) == TYPE_DICTIONARY:
		for k in extra:
			body[k] = extra[k]
	return body


## {ok, message, finish_reason, model, error} from a decoded chat-completions response.
static func parse_chat_response(status: int, parsed) -> Dictionary:
	var out := {"ok": false, "message": {}, "finish_reason": "", "error": ""}
	if status != 200:
		out.error = _http_error(status, parsed)
		return out
	if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("choices")) != TYPE_ARRAY or parsed.choices.is_empty():
		out.error = "Unexpected response from NVIDIA NIM."
		return out
	var choice = parsed.choices[0]
	if typeof(choice) != TYPE_DICTIONARY or typeof(choice.get("message")) != TYPE_DICTIONARY:
		out.error = "Unexpected response from NVIDIA NIM."
		return out
	out.message = choice.message
	out.finish_reason = str(choice.get("finish_reason", ""))
	if parsed.has("model"):
		out["model"] = str(parsed.model)
	out.ok = true
	return out


## Reasoning models may wrap their thinking in <think>…</think>; speak only the answer.
static func strip_thinking(text: String) -> String:
	var re := RegEx.new()
	re.compile("(?s)<think>.*?</think>")
	var t := re.sub(text, "", true)
	var tail := t.find("</think>")
	if tail >= 0:
		t = t.substr(tail + 8)
	return t.strip_edges()


static func _http_error(code: int, parsed) -> String:
	var detail := ""
	if typeof(parsed) == TYPE_DICTIONARY:
		var e = parsed.get("error")
		if typeof(e) == TYPE_DICTIONARY:
			detail = str(e.get("message", ""))
		elif typeof(e) == TYPE_STRING:
			detail = e
		elif parsed.has("detail"):
			detail = str(parsed.get("detail"))
	match code:
		401, 403:
			return "NVIDIA NIM rejected the API key. Check NVIDIA_API_KEY in .env."
		404:
			return "NVIDIA NIM model not found: " + detail
		400, 422:
			return "NVIDIA NIM rejected the request: " + detail
		429:
			return "NVIDIA NIM is rate-limiting us. Give it a moment."
		500, 502, 503, 504:
			return "NVIDIA NIM is having trouble right now. Try again in a bit."
		_:
			return "NVIDIA NIM error %d. %s" % [code, detail]
