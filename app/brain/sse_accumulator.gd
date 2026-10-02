class_name SseAccumulator
extends RefCounted
## Turns an OpenAI-style server-sent-event stream (chat completions with stream=true) into the same
## assistant message a non-streaming response carries: {role, content, tool_calls}. Bytes may arrive in
## arbitrary pieces (a line can be split across chunks). Reasoning deltas (reasoning_content / reasoning)
## are dropped here, so they can never reach the answer, the UI or the text-to-speech.

var text := ""
var tool_calls: Array = []            # [{id, type, function: {name, arguments}}], ordered by index
var finish_reason := ""
var model := ""
var done := false
var error := ""                       # an error object inside the stream
var saw_tool_call := false
var first_delta_ms := -1
var on_text := Callable()             # func(delta: String), for each content delta
var _buffer := ""
var _by_index := {}
var _t0 := 0


func _init(text_callback: Callable = Callable()) -> void:
	on_text = text_callback
	_t0 = Time.get_ticks_msec()


func feed(bytes: PackedByteArray) -> void:
	_buffer += bytes.get_string_from_utf8()
	while true:
		var nl := _buffer.find("\n")
		if nl < 0:
			return
		var line := _buffer.substr(0, nl).strip_edges(false, true)
		_buffer = _buffer.substr(nl + 1)
		_line(line)


## Whatever is left in the buffer when the connection ends without a final newline.
func finish() -> void:
	if _buffer.strip_edges() != "":
		_line(_buffer.strip_edges())
		_buffer = ""


func _line(line: String) -> void:
	if not line.begins_with("data:"):
		return
	var payload := line.substr(5).strip_edges()
	if payload == "[DONE]":
		done = true
		return
	var json := JSON.new()
	if json.parse(payload) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = json.data
	if d.has("error"):
		error = str(d.error.get("message", d.error)) if typeof(d.error) == TYPE_DICTIONARY else str(d.error)
		return
	if d.has("model"):
		model = str(d.model)
	var choices = d.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
		return
	var choice: Dictionary = choices[0]
	if choice.get("finish_reason") != null:
		finish_reason = str(choice.finish_reason)
	var delta = choice.get("delta", {})
	if typeof(delta) != TYPE_DICTIONARY:
		return
	var content = delta.get("content")
	if typeof(content) == TYPE_STRING and content != "":
		_mark_first()
		text += content
		if on_text.is_valid():
			on_text.call(content)
	var calls = delta.get("tool_calls")
	if typeof(calls) == TYPE_ARRAY:
		for c in calls:
			if typeof(c) != TYPE_DICTIONARY:
				continue
			_mark_first()
			saw_tool_call = true
			var idx := int(c.get("index", 0))
			if not _by_index.has(idx):
				_by_index[idx] = {"id": "", "type": "function", "function": {"name": "", "arguments": ""}}
			var slot: Dictionary = _by_index[idx]
			if c.get("id") != null and str(c.id) != "":
				slot.id = str(c.id)
			var fn = c.get("function", {})
			if typeof(fn) == TYPE_DICTIONARY:
				if fn.get("name") != null and str(fn.name) != "" and str(slot.function.name) == "":
					slot.function.name = str(fn.name)      # the name comes whole in the first delta
				if fn.get("arguments") != null:
					slot.function.arguments = str(slot.function.arguments) + str(fn.arguments)
	tool_calls = []
	var keys := _by_index.keys()
	keys.sort()
	for k in keys:
		tool_calls.append(_by_index[k])


func _mark_first() -> void:
	if first_delta_ms < 0:
		first_delta_ms = Time.get_ticks_msec() - _t0


## The assistant message exactly as a non-streaming reply would carry it.
func message() -> Dictionary:
	var m := {"role": "assistant", "content": text if text != "" else null}
	if not tool_calls.is_empty():
		m["tool_calls"] = tool_calls
	return m
