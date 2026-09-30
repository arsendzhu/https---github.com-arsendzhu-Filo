class_name HelperBridge
extends Node
## Talks to the native macOS helper (global push-to-talk hotkey + on-device
## speech recognition + running-app list) over a localhost TCP socket using
## newline-delimited JSON. Godot listens; the helper connects.
##
## helper -> app events: ready, hotkey_down, hotkey_up{duration_ms}, tap,
##   wake_word{phrase}, partial{text}, final{text}, level{value},
##   apps{apps:[{name,bundle_id}]}, error{code,message}, pong, mute_state{muted,source}, panic (the panic hotkey)
## app -> helper commands: ping, list_apps, wake_pause, wake_resume, set_wake{enabled}, quit,
##   set_mute{muted} (microphone off; acknowledged with mute_state), focus_save / focus_restore
##   (give keyboard focus back to the game after the typed-question box)

signal connected
signal disconnected
signal helper_ready(info: Dictionary)
signal hotkey_down
signal hotkey_up(duration_ms: int)
signal tap
signal partial_transcript(text: String)
signal final_transcript(text: String)
signal level(value: float)
signal apps(list: Array)
signal helper_error(code: String, message: String)
signal wake_word(phrase: String)
signal listen_timeout
signal bye
signal mute_state(muted: bool, source: String)
signal panic

var port := 47821
var launched := false
var pid := -1
var _server := TCPServer.new()
var _peer: StreamPeerTCP
var _buffer := PackedByteArray()


func start_listening(listen_port: int) -> Error:
	port = listen_port
	var err := _server.listen(port, "127.0.0.1")
	if err != OK:
		FiloLog.error("Could not listen on 127.0.0.1:%d (error %d). Is another Filo running?" % [port, err])
	return err


## Launches the helper. An .app bundle is launched through `open` so macOS
## treats it as its own app for microphone / speech permissions; anything else
## is executed directly (used by the fake helper in tests).
func launch(path: String, extra_args: PackedStringArray, hotkey_key: String, hotkey_mods: Array, allow_server_speech: bool, locale: String, wake_phrase: String = "", wake_silence_ms: int = 1500, more_args: PackedStringArray = PackedStringArray()) -> bool:
	# extra_args go first so an interpreter + script (e.g. python3 fake_helper.py) works too
	var args := PackedStringArray()
	args.append_array(extra_args)
	args.append_array(PackedStringArray(["--port", str(port), "--key", hotkey_key, "--mods", ",".join(PackedStringArray(hotkey_mods)), "--locale", locale]))
	if allow_server_speech:
		args.append("--allow-server-speech")
	if wake_phrase.strip_edges() != "":
		args.append_array(PackedStringArray(["--wake-word", wake_phrase.strip_edges(), "--wake-silence-ms", str(wake_silence_ms)]))
	args.append_array(more_args)
	if path.ends_with(".app"):
		if not DirAccess.dir_exists_absolute(path):
			FiloLog.error("Helper app not found: " + path)
			return false
		var open_args := PackedStringArray(["-g", "-n", "-a", path, "--args"])
		open_args.append_array(args)
		pid = OS.create_process("/usr/bin/open", open_args)
	else:
		if not FileAccess.file_exists(path) and not path.begins_with("/usr/bin") and OS.execute("/usr/bin/which", [path]) != 0:
			FiloLog.error("Helper executable not found: " + path)
			return false
		pid = OS.create_process(path, args)
	launched = pid > 0
	if launched:
		FiloLog.info("Helper launched: %s %s" % [path, " ".join(args)])
	else:
		FiloLog.error("Failed to launch helper: " + path)
	return launched


func is_connected_to_helper() -> bool:
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send(cmd: Dictionary) -> void:
	if is_connected_to_helper():
		_peer.put_data((JSON.stringify(cmd) + "\n").to_utf8_buffer())


func shutdown() -> void:
	send({"cmd": "quit"})
	if _peer:
		_peer.disconnect_from_host()
		_peer = null
	_server.stop()
	if launched and pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _process(_delta: float) -> void:
	if _peer == null:
		if _server.is_listening() and _server.is_connection_available():
			_peer = _server.take_connection()
			_peer.set_no_delay(true)
			_buffer = PackedByteArray()
			FiloLog.info("Helper connected")
			connected.emit()
		return
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		var n := _peer.get_available_bytes()
		if n > 0:
			var res: Array = _peer.get_partial_data(n)
			if res[0] == OK:
				_buffer.append_array(res[1])
				_drain()
	elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		FiloLog.warn("Helper disconnected")
		_peer = null
		disconnected.emit()


func _drain() -> void:
	while true:
		var idx := _buffer.find(10)
		if idx < 0:
			return
		var line := _buffer.slice(0, idx).get_string_from_utf8().strip_edges()
		_buffer = _buffer.slice(idx + 1)
		if line != "":
			_handle_line(line)


func _handle_line(line: String) -> void:
	var parsed = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		FiloLog.warn("Unparseable helper line: " + line.left(120))
		return
	var ev := str(parsed.get("event", ""))
	if ev != "level":
		FiloLog.debug("helper -> " + line.left(200))
	match ev:
		"ready":
			helper_ready.emit(parsed)
		"hotkey_down":
			hotkey_down.emit()
		"hotkey_up":
			hotkey_up.emit(int(parsed.get("duration_ms", 0)))
		"tap":
			tap.emit()
		"wake_word":
			wake_word.emit(str(parsed.get("phrase", "")))
		"listen_timeout":
			listen_timeout.emit()
		"bye":
			bye.emit()
		"partial":
			partial_transcript.emit(str(parsed.get("text", "")))
		"final":
			final_transcript.emit(str(parsed.get("text", "")))
		"level":
			level.emit(float(parsed.get("value", 0.0)))
		"apps":
			apps.emit(parsed.get("apps", []))
		"error":
			helper_error.emit(str(parsed.get("code", "")), str(parsed.get("message", "")))
		"mute_state":
			mute_state.emit(bool(parsed.get("muted", false)), str(parsed.get("source", "command")))
		"panic":
			panic.emit()
		"pong":
			pass
		_:
			FiloLog.debug("Unknown helper event: " + ev)
