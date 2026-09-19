class_name ClaudeClient
extends Node
## Raw-HTTP client for the Claude Messages API (GDScript has no official SDK).
## - model / effort / max_tokens from config
## - server-side refusal fallbacks ("fallbacks": "default") opted in by default
## - optional web_search server tool (web_search_20260209)
## - handles stop_reason "refusal" and "pause_turn" continuation

const API_VERSION := "2023-06-01"
const FALLBACK_BETA := "server-side-fallback-2026-07-01"

var api_key := ""
var base_url := "https://api.anthropic.com"
var model := "claude-opus-5"
var effort := "low"
var max_tokens := 700
var refusal_fallbacks := true
var timeout_sec := 75.0
var last_request: Dictionary = {}


func configure(cfg: FiloConfig) -> void:
	api_key = str(cfg.get_value("anthropic_api_key", ""))
	base_url = str(cfg.get_value("api_base_url", base_url)).trim_suffix("/")
	model = str(cfg.get_value("model", model))
	effort = str(cfg.get_value("effort", effort))
	max_tokens = int(cfg.get_value("max_tokens", max_tokens))
	refusal_fallbacks = bool(cfg.get_value("refusal_fallbacks", true))


func has_key() -> bool:
	return api_key.strip_edges() != ""


func build_request(system_prompt: String, messages: Array, tools: Array) -> Dictionary:
	var body := {
		"model": model,
		"max_tokens": max_tokens,
		"system": system_prompt,
		"messages": messages,
	}
	# effort is supported on the Claude 5 / Opus 4.6+ families, not on Haiku 4.5
	if effort != "" and not model.begins_with("claude-haiku"):
		body["output_config"] = {"effort": effort}
	if refusal_fallbacks:
		body["fallbacks"] = "default"
	if tools.size() > 0:
		body["tools"] = tools
	return body


func build_headers() -> PackedStringArray:
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"x-api-key: " + api_key,
		"anthropic-version: " + API_VERSION,
	])
	if refusal_fallbacks:
		headers.append("anthropic-beta: " + FALLBACK_BETA)
	return headers


## Sends one question. Returns:
## {ok, text, citations: [{url,title}], searched: [{url,title}], error, model, stop_reason}
func ask(system_prompt: String, user_content: String, tools: Array = []) -> Dictionary:
	var out := {"ok": false, "text": "", "citations": [], "searched": [], "error": "", "model": "", "stop_reason": ""}
	if not has_key():
		out.error = "No Anthropic API key configured."
		return out
	var messages: Array = [{"role": "user", "content": user_content}]
	var continuations := 0
	while true:
		var body := build_request(system_prompt, messages, tools)
		last_request = body
		var http := HTTPRequest.new()
		http.timeout = timeout_sec
		http.accept_gzip = true
		add_child(http)
		var started := Time.get_ticks_msec()
		var err := http.request(base_url + "/v1/messages", build_headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
		if err != OK:
			http.queue_free()
			out.error = "Could not start the request (error %d)." % err
			return out
		var res: Array = await http.request_completed
		http.queue_free()
		var result: int = res[0]
		var code: int = res[1]
		var raw: PackedByteArray = res[3]
		FiloLog.debug("Claude HTTP %d in %d ms (result %d)" % [code, Time.get_ticks_msec() - started, result])
		if result != HTTPRequest.RESULT_SUCCESS:
			out.error = _result_error(result)
			return out
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		if code != 200:
			out.error = _http_error(code, parsed)
			return out
		if typeof(parsed) != TYPE_DICTIONARY:
			out.error = "Unexpected response from Claude."
			return out
		out.model = str(parsed.get("model", ""))
		out.stop_reason = str(parsed.get("stop_reason", ""))
		var content: Array = parsed.get("content", [])
		_collect(content, out)
		if out.stop_reason == "refusal":
			out.error = "Claude declined to answer that one."
			return out
		if out.stop_reason == "pause_turn" and continuations < 2:
			continuations += 1
			messages.append({"role": "assistant", "content": content})
			continue
		out.ok = out.text.strip_edges() != ""
		if not out.ok:
			out.error = "Claude returned an empty answer."
		return out
	return out


func _collect(content: Array, out: Dictionary) -> void:
	for block in content:
		if typeof(block) != TYPE_DICTIONARY:
			continue
		var t := str(block.get("type", ""))
		if t == "text":
			out.text += str(block.get("text", ""))
			for c in block.get("citations", []):
				if typeof(c) == TYPE_DICTIONARY and c.has("url"):
					_add_unique(out.citations, {"url": str(c.get("url", "")), "title": str(c.get("title", ""))})
		elif t == "web_search_tool_result":
			var inner = block.get("content")
			if typeof(inner) == TYPE_ARRAY:
				for r in inner:
					if typeof(r) == TYPE_DICTIONARY and str(r.get("type", "")) == "web_search_result":
						_add_unique(out.searched, {"url": str(r.get("url", "")), "title": str(r.get("title", ""))})
			elif typeof(inner) == TYPE_DICTIONARY:
				FiloLog.warn("web_search error: " + str(inner.get("error_code", "unknown")))


static func _add_unique(list: Array, entry: Dictionary) -> void:
	for e in list:
		if e.url == entry.url:
			return
	list.append(entry)


static func _result_error(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			return "I can't reach Claude — is the internet connected?"
		HTTPRequest.RESULT_TIMEOUT:
			return "Claude took too long to answer. Try again."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Secure connection to Claude failed."
		_:
			return "Request to Claude failed (code %d)." % result


static func _http_error(code: int, parsed) -> String:
	var detail := ""
	if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("error")) == TYPE_DICTIONARY:
		detail = str(parsed["error"].get("message", ""))
	match code:
		401:
			return "Claude rejected the API key. Check anthropic_api_key in config.json."
		403:
			return "This API key isn't allowed to do that. " + detail
		400:
			return "Claude rejected the request: " + detail
		404:
			return "Model not found: " + detail
		429:
			return "Claude is rate-limiting us. Give it a moment."
		500, 502, 503, 529:
			return "Claude is overloaded right now. Try again in a bit."
		_:
			return "Claude API error %d. %s" % [code, detail]
