class_name Speaker
extends Node
## Text-to-speech with two providers:
##   system — Godot's DisplayServer TTS (AVSpeechSynthesizer; Apple premium voices
##            when installed). Word boundaries drive the mouth and the text reveal.
##   kokoro — a local neural voice (Kokoro-82M via tts/kokoro_server.py, offline,
##            free). The whole utterance is synthesized in a single request, then
##            played as one continuous buffer — no mid-speech network activity,
##            so there is nothing to cause a gap or stutter once playback starts.
##            The mouth follows the audio's RMS envelope; the text reveal follows
##            estimated per-word timing across the same buffer.
## "auto" uses kokoro when its server is (or becomes) reachable, else system.
## Muted/unavailable: timing is simulated so every animation still runs.

signal started(utterance_id: int)
signal boundary(char_index: int, utterance_id: int)
signal finished(utterance_id: int)
signal cancelled(utterance_id: int)
signal mouth_level(level: float)

var enabled := true
var user_muted := false          # runtime mute toggle (the bubble's sound button), separate from `enabled`
var provider := "auto"           # auto | system | kokoro
var voice_id := ""
var voice_name := ""
var rate := 1.0
var pitch := 1.0
var volume := 70
var available := false
var kokoro_url := "http://127.0.0.1:47823"
var kokoro_voice := "af_heart"
var kokoro_speed := 1.05
var kokoro_ready := false
var kokoro_pid := -1

var _next_id := 1
var _current_id := 0
var _sim_timer: Timer
var _sim_text := ""
var _sim_positions: PackedInt32Array = PackedInt32Array()
var _sim_index := 0
var _player: AudioStreamPlayer
var _health_timer: Timer
var _envelope: PackedFloat32Array = PackedFloat32Array()
var _env_step := 0.05
var _full_text := ""
var _word_starts: PackedInt32Array = PackedInt32Array()
var _next_word := 0
var _speech_duration := 0.0
var _root := ""
# One logical utterance can arrive in two parts: a head (the first sentence, spoken as soon as it exists) and a
# tail (the rest, appended later). Callers still see ONE started ... finished.
var _more_expected := false          # the head was started with more to come (append / end_stream)
var _end_stream_called := false
var _head_done := false              # the head finished playing; waiting for the tail
var _tail_text := ""
var _tail_started := false
var _tail_ready := false             # kokoro: the tail's audio is synthesized
var _tail_data := {}                 # parsed wav of the tail
var _text_offset := 0                # boundary positions of the tail are shifted by the head's length + 1


func setup(cfg: FiloConfig) -> void:
	enabled = bool(cfg.get_value("tts.enabled", true))
	provider = str(cfg.get_value("tts.provider", "auto")).to_lower()
	rate = float(cfg.get_value("tts.rate", 1.0))
	pitch = float(cfg.get_value("tts.pitch", 1.0))
	volume = int(cfg.get_value("tts.volume", 70))
	kokoro_voice = str(cfg.get_value("tts.kokoro.voice", "af_heart"))
	kokoro_speed = float(cfg.get_value("tts.kokoro.speed", 1.05))
	kokoro_url = "http://127.0.0.1:%d" % int(cfg.get_value("tts.kokoro.port", 47823))
	_root = FiloConfig.project_root()
	available = DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH)
	if available and enabled:
		DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_STARTED, _on_tts_started)
		DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_tts_ended)
		DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_CANCELED, _on_tts_canceled)
		DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_BOUNDARY, _on_tts_boundary)
		_pick_voice(str(cfg.get_value("tts.voice", "")))
		FiloLog.info("System voice: '%s' (%s)%s" % [voice_name, voice_id, "" if _voice_quality_rank(voice_id) >= 3 else " — compact voice; download a premium one in System Settings › Accessibility › Spoken Content for a much nicer sound"])
	else:
		FiloLog.info("TTS %s — speech timing will be simulated" % ("disabled" if not enabled else "unavailable"))
	_sim_timer = Timer.new()
	_sim_timer.one_shot = true
	add_child(_sim_timer)
	_sim_timer.timeout.connect(_sim_step)
	_player = AudioStreamPlayer.new()
	_player.name = "KokoroPlayer"
	add_child(_player)
	_player.finished.connect(_on_player_finished)
	if enabled and provider in ["auto", "kokoro"]:
		_start_kokoro()


func _process(_delta: float) -> void:
	if _current_id == 0 or not _player.playing:
		return
	var pos := _player.get_playback_position()
	if not _envelope.is_empty():
		var idx := int(pos / _env_step)
		if idx >= 0 and idx < _envelope.size():
			mouth_level.emit(_envelope[idx])
	while _next_word < _word_starts.size() and _speech_duration > 0.0:
		var frac := float(_word_starts[_next_word]) / maxf(_full_text.length(), 1.0)
		if pos >= frac * _speech_duration:
			boundary.emit(_word_starts[_next_word] + _text_offset, _current_id)
			_next_word += 1
		else:
			break


func is_speaking() -> bool:
	return _current_id != 0


## Runtime mute toggle (the bubble's sound button). Independent of `enabled`
## (the persisted config setting): resets to `enabled` on every fresh launch,
## this is a session-only override on top of it.
func set_muted(m: bool) -> void:
	user_muted = m


func active_provider() -> String:
	if not enabled or user_muted:
		return "muted"
	if provider in ["auto", "kokoro"] and kokoro_ready:
		return "kokoro"
	if available and voice_id != "":
		return "system"
	return "simulated"


## `expect_more`: this is only the first part of the answer; the rest follows with append() (or end_stream()).
func speak(text: String, expect_more: bool = false) -> int:
	stop()
	_reset_continuation()
	_full_text = text                  # the head; boundary offsets for an appended tail are counted from its end
	_more_expected = expect_more
	_current_id = _next_id
	_next_id += 1
	var id := _current_id
	match active_provider():
		"kokoro":
			_speak_kokoro(text, id)
		"system":
			DisplayServer.tts_speak(text, voice_id, volume, pitch, rate, id, true)
		_:
			_simulate(text, id)
	return id


## Stops the current utterance and reports it as cancelled (a deliberate
## interruption — the hotkey pressed mid-answer, a new question, dismissal).
func stop() -> void:
	if _current_id == 0:
		return
	var id := _cleanup()
	cancelled.emit(id)


## Safety valve for a watchdog: stops the current utterance the same way
## stop() does, but reports it as finished rather than cancelled, so the
## normal after-speech flow (reprompt / farewell / wake resume) still runs
## even if playback got stuck for a reason we didn't anticipate.
func force_finish() -> void:
	if _current_id == 0:
		return
	var id := _cleanup()
	finished.emit(id)


## The rest of the answer, after speak(head, true). It starts as soon as the head has finished playing (a Kokoro
## tail is synthesized in the meantime, so there is no gap). Only the first call counts.
func append(text: String) -> void:
	if _current_id == 0 or _tail_text != "" or _end_stream_called:
		return
	_more_expected = false
	_tail_text = text.strip_edges()
	if _tail_text == "":
		end_stream()
		return
	_text_offset = _full_text.length() + 1
	if active_provider() == "kokoro":
		_prepare_kokoro_tail(_tail_text, _current_id)
	else:
		_tail_ready = true
	_try_continue()


## No more text is coming after the head: finish once it has been spoken.
func end_stream() -> void:
	if _current_id == 0:
		return
	_more_expected = false
	_end_stream_called = true
	_try_continue()


func _reset_continuation() -> void:
	_more_expected = false
	_end_stream_called = false
	_head_done = false
	_tail_text = ""
	_tail_started = false
	_tail_ready = false
	_tail_data = {}
	_text_offset = 0


## A part (the head, or the tail) finished playing.
func _part_finished(id: int) -> void:
	if id != _current_id:
		return
	if not _tail_started and (_more_expected or _tail_text != ""):
		_head_done = true
		_try_continue()
		return
	_reset_continuation()
	_current_id = 0
	_envelope = PackedFloat32Array()
	finished.emit(id)


func _try_continue() -> void:
	if _current_id == 0 or not _head_done:
		return                                   # the head is still playing; it calls back when it ends
	if _tail_text != "" and not _tail_started:
		if not _tail_ready:
			return                               # kokoro is still synthesizing the tail; its callback comes back here
		_tail_started = true
		_play_tail()
	elif _tail_text == "" and _end_stream_called:
		var id := _current_id
		_reset_continuation()
		_current_id = 0
		_envelope = PackedFloat32Array()
		finished.emit(id)


func _play_tail() -> void:
	var id := _current_id
	match active_provider():
		"kokoro":
			if _tail_data.is_empty():
				_kokoro_failed(id, "no tail audio")
				return
			_full_text = _tail_text
			_word_starts = _compute_word_starts(_tail_text)
			_next_word = 0
			_play_parsed(_tail_data)
		"system":
			DisplayServer.tts_speak(_tail_text, voice_id, volume, pitch, rate, id, true)
		_:
			_sim_text = _tail_text
			_sim_positions = _compute_word_starts(_tail_text)
			_sim_index = 0
			_sim_step()


func _cleanup() -> int:
	var id := _current_id
	_current_id = 0
	_reset_continuation()
	if available and enabled:
		DisplayServer.tts_stop()
	_sim_timer.stop()
	_player.stop()
	_envelope = PackedFloat32Array()
	return id


func shutdown() -> void:
	stop()
	if kokoro_pid > 0 and OS.is_process_running(kokoro_pid):
		OS.kill(kokoro_pid)


# ------------------------------------------------------------- system voice

## `preferred` may list several names ("Ava, Zoe, Samantha"): the first name
## that is installed wins, and its best-quality variant is chosen.
func _pick_voice(preferred: String) -> void:
	var voices := DisplayServer.tts_get_voices()
	var best := {}
	var fallback := {}
	for v in voices:
		if str(v.get("language", "")).begins_with("en") and fallback.is_empty():
			fallback = v
	for wanted in preferred.split(",", false):
		var name := wanted.strip_edges().to_lower()
		if name == "":
			continue
		var best_rank := -1
		for v in voices:
			if not str(v.get("language", "")).begins_with("en"):
				continue
			if str(v.get("name", "")).to_lower().contains(name):
				var rank := _voice_quality_rank(str(v.get("id", "")))
				if rank > best_rank:
					best = v
					best_rank = rank
		if not best.is_empty():
			break
	if best.is_empty():
		best = fallback
	if best.is_empty() and voices.size() > 0:
		best = voices[0]
	if not best.is_empty():
		voice_id = str(best.get("id", ""))
		voice_name = str(best.get("name", ""))


## macOS voice ids encode the quality tier; prefer the best installed variant.
static func _voice_quality_rank(id: String) -> int:
	var lower := id.to_lower()
	if lower.contains("premium"):
		return 4
	if lower.contains("enhanced"):
		return 3
	if lower.contains("super-compact"):
		return 1
	if lower.contains("compact"):
		return 2
	return 2


func _on_tts_started(id: int) -> void:
	if id == _current_id:
		started.emit(id)


func _on_tts_ended(id: int) -> void:
	if id == _current_id:
		_part_finished(id)


func _on_tts_canceled(id: int) -> void:
	if id == _current_id:
		_current_id = 0
	cancelled.emit(id)


func _on_tts_boundary(pos: int, id: int) -> void:
	if id == _current_id:
		boundary.emit(pos + _text_offset, id)


# ------------------------------------------------------------------ kokoro

func _start_kokoro() -> void:
	var python := _root.path_join("tts/venv/bin/python3")
	var server := _root.path_join("tts/kokoro_server.py")
	var model := _root.path_join("tts/models/kokoro-v1.0.onnx")
	if not FileAccess.file_exists(python) or not FileAccess.file_exists(server) or not FileAccess.file_exists(model):
		if provider == "kokoro":
			FiloLog.warn("Kokoro voice requested but tts/venv or the model files are missing — run scripts/setup_voice.sh; using the system voice")
		return
	kokoro_pid = OS.create_process(python, PackedStringArray([server, "--port", str(int(kokoro_url.get_slice(":", 2))), "--voice", kokoro_voice]))
	if kokoro_pid <= 0:
		FiloLog.warn("Could not start the Kokoro voice server; using the system voice")
		return
	FiloLog.info("Kokoro voice server starting (pid %d)…" % kokoro_pid)
	_health_timer = Timer.new()
	_health_timer.wait_time = 1.5
	add_child(_health_timer)
	_health_timer.timeout.connect(_check_kokoro_health)
	_health_timer.start()


func _check_kokoro_health() -> void:
	if kokoro_ready:
		_health_timer.stop()
		return
	var http := HTTPRequest.new()
	http.timeout = 2.0
	add_child(http)
	if http.request(kokoro_url + "/health") != OK:
		http.queue_free()
		return
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
		kokoro_ready = true
		_health_timer.stop()
		FiloLog.info("Kokoro voice ready (%s) — local neural voice in use" % kokoro_voice)


## One HTTP request for the whole utterance, then one continuous playback.
## No further network activity happens once .play() is called, so there is
## nothing that can stall or gap mid-speech.
func _speak_kokoro(text: String, id: int) -> void:
	_full_text = text
	_word_starts = _compute_word_starts(text)
	_next_word = 0
	started.emit(id)
	var http := HTTPRequest.new()
	http.timeout = 45.0
	add_child(http)
	var body := JSON.stringify({"text": text, "voice": kokoro_voice, "speed": kokoro_speed})
	var started_ms := Time.get_ticks_msec()
	var err := http.request(kokoro_url + "/synthesize", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		_kokoro_failed(id, "request error %d" % err)
		return
	var res: Array = await http.request_completed
	http.queue_free()
	var code: int = res[1]
	FiloLog.debug("Kokoro HTTP %d in %d ms (%d chars)" % [code, Time.get_ticks_msec() - started_ms, text.length()])
	if id != _current_id:
		return
	if res[0] != HTTPRequest.RESULT_SUCCESS or code != 200:
		_kokoro_failed(id, "HTTP %d" % code)
		return
	var parsed := _parse_wav(res[3])
	if parsed.is_empty():
		_kokoro_failed(id, "bad wav")
		return
	_play_parsed(parsed)


func _play_parsed(parsed: Dictionary) -> void:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(parsed.rate)
	stream.stereo = false
	stream.data = parsed.data
	_envelope = parsed.envelope
	_speech_duration = float(parsed.duration)
	_player.stream = stream
	_player.volume_db = linear_to_db(clampf(volume / 100.0, 0.05, 1.0))
	_player.play()


## Synthesizes the tail while the head is still playing (one request for the whole tail).
func _prepare_kokoro_tail(text: String, id: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = 45.0
	add_child(http)
	var body := JSON.stringify({"text": text, "voice": kokoro_voice, "speed": kokoro_speed})
	if http.request(kokoro_url + "/synthesize", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST, body) != OK:
		http.queue_free()
		_tail_ready = true          # _play_tail reports the failure and falls back to another voice
		_try_continue()
		return
	var res: Array = await http.request_completed
	http.queue_free()
	if id != _current_id:
		return
	if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
		_tail_data = _parse_wav(res[3])
	_tail_ready = true
	_try_continue()


func _on_player_finished() -> void:
	if _current_id == 0:
		return
	_part_finished(_current_id)


func _kokoro_failed(id: int, why: String) -> void:
	FiloLog.warn("Kokoro voice failed (%s) — falling back to the system voice" % why)
	kokoro_ready = false
	if id != _current_id:
		return
	var text := _tail_text if _tail_started else _full_text
	if available and voice_id != "":
		DisplayServer.tts_speak(text, voice_id, volume, pitch, rate, id, true)
	else:
		_sim_text = text
		_sim_positions = _compute_word_starts(text)
		_sim_index = 0
		if _tail_started:
			_sim_step()
		else:
			call_deferred("_sim_start", id)


## Character offset of the start of each word (whitespace-split) in `text`.
static func _compute_word_starts(text: String) -> PackedInt32Array:
	var starts := PackedInt32Array()
	var pos := 0
	for word in text.split(" ", false):
		var at := text.find(word, pos)
		if at < 0:
			at = pos
		starts.append(at)
		pos = at + word.length()
	return starts


## 16-bit mono PCM WAV -> {data, rate, duration, envelope (RMS per 50 ms, 0..1)}.
## The envelope only needs to be smooth, not sample-accurate, so each 50 ms
## window is measured from a stride of samples rather than every single one —
## keeps this a light one-time cost before playback starts, not a per-sample
## scan of the whole (possibly many-second) buffer.
static func _parse_wav(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return {}
	var rate := bytes.decode_u32(24)
	var channels := bytes.decode_u16(22)
	var bits := bytes.decode_u16(34)
	if channels != 1 or bits != 16:
		return {}
	var pos := 12
	var data := PackedByteArray()
	while pos + 8 <= bytes.size():
		var chunk_id := bytes.slice(pos, pos + 4).get_string_from_ascii()
		var chunk_size := bytes.decode_u32(pos + 4)
		if chunk_id == "data":
			data = bytes.slice(pos + 8, mini(pos + 8 + chunk_size, bytes.size()))
			break
		pos += 8 + chunk_size
	if data.is_empty():
		return {}
	var samples := data.size() / 2
	var duration := float(samples) / float(rate)
	var step_samples := maxi(int(rate * 0.05), 1)
	var stride := maxi(step_samples / 250, 1)
	var envelope := PackedFloat32Array()
	var i := 0
	var peak := 0.0
	while i < samples:
		var sum := 0.0
		var n := 0
		var j := i
		var window_end := mini(i + step_samples, samples)
		while j < window_end:
			var v := float(data.decode_s16(j * 2)) / 32768.0
			sum += v * v
			n += 1
			j += stride
		var rms := sqrt(sum / maxf(n, 1.0))
		envelope.append(rms)
		peak = maxf(peak, rms)
		i += step_samples
	if peak > 0.0:
		for k in envelope.size():
			envelope[k] = clampf(envelope[k] / peak * 1.4, 0.0, 1.0)
	return {"data": data, "rate": rate, "duration": duration, "envelope": envelope}


# --- simulated timing when muted/unavailable ---

func _simulate(text: String, id: int) -> void:
	_sim_text = text
	_sim_positions = PackedInt32Array()
	var pos := 0
	for word in text.split(" ", false):
		var idx := text.find(word, pos)
		if idx < 0:
			idx = pos
		_sim_positions.append(idx)
		pos = idx + word.length()
	_sim_index = 0
	call_deferred("_sim_start", id)


func _sim_start(id: int) -> void:
	if id != _current_id:
		return
	started.emit(id)
	_sim_step()


func _sim_step() -> void:
	if _current_id == 0:
		return
	if _sim_index >= _sim_positions.size():
		_part_finished(_current_id)
		return
	var start: int = _sim_positions[_sim_index]
	boundary.emit(start + _text_offset, _current_id)
	var next_start: int = _sim_positions[_sim_index + 1] if _sim_index + 1 < _sim_positions.size() else _sim_text.length()
	var word_len := maxi(next_start - start, 1)
	_sim_index += 1
	_sim_timer.start(0.09 + 0.045 * word_len)
