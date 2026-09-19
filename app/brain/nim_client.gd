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


func configure(cfg: FiloConfig) -> void:
	api_key = str(cfg.get_value("nvidia_api_key", ""))
	base_url = str(cfg.get_value("nim.base_url", base_url)).trim_suffix("/")
	model = str(cfg.get_value("nim.model", model))
	max_tokens = int(cfg.get_value("nim.max_tokens", max_tokens))
	temperature = float(cfg.get_value("nim.temperature", temperature))
	reasoning = bool(cfg.get_value("nim.reasoning", false))


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
