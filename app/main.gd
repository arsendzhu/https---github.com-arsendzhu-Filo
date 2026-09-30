extends Control
## Filo — Phase 0 Mac-native shell.
## Wires together: overlay window, mascot (+animations), helper bridge
## (global push-to-talk hotkey + speech), answer pipeline (notes -> optional
## web search -> Claude), speech output and the bubble UI.
##
## Interaction model ("hey filo" wake word + push-to-talk hotkey, default ⌥ Space):
##   say "hey filo" / hold the key -> summon + listen; release or pause -> think -> answer
##   after each answer Filo asks "anything else?" and keeps listening (follow-up mode)
##   "bye filo" or a tap of the key -> dismiss   ·   tap while asleep -> typed question

enum AppState { ASLEEP, WAKING, IDLE, LISTENING, THINKING, ANSWERING, TYPING, SLEEPING }

## Every question, however it was entered ("voice" | "typed"), goes through _ask(); tests watch this.
signal question_asked(text: String, source: String)

const HINT_COLOR := Color("bfb3a6")

var cfg: FiloConfig
var args: Dictionary = {}
var profile: GameProfile
var profiles_dir := ""
var bridge: HelperBridge
var mascot: Mascot
var bubble: Bubble
var input_panel: InputPanel
var controls: ControlBar
var hint: Label
var pipeline: AnswerPipeline
var speaker: Speaker
var showcase: Showcase
var win_info: Dictionary = {}

var app_state: int = AppState.ASLEEP
var idle_timer: Timer
var linger_timer: Timer
var final_timer: Timer
var speech_watchdog: Timer
var apps_timer: Timer
var helper_watchdog: Timer
var hint_tween: Tween
var helper_connected := false

var _wake_target: int = AppState.IDLE
var _pending_final := false
var _has_queued_final := false
var _queued_final := ""
var _last_partial := ""
var _answer_token := 0
var _scripted := false
var _quit_after_sleep := false
var _quitting := false
var _profile_cache: Dictionary = {}
var _press_origin: int = AppState.ASLEEP
var _press_origin_valid := false
var _followup := false          # LISTENING opened by Filo after an answer
var _followup_mode := "voice"   # voice | text — which mode the next reprompt uses
var _had_first_answer := false  # the mode button only appears once there's something to follow up on
var _fallback_interactive := false   # true once the window has to stay fully interactive (no helper)
var mic_muted := false          # microphone capture muted (helper stops listening); separate from the voice (TTS) mute
var mic_mute_confirmed := false # the helper acknowledged the last set_mute
var window_state := {"passthrough": true, "unfocusable": true}   # the click-through / focus mode last requested for the window
var _mute_deadline := 0.0
var _focus_saved := false       # focus_save was sent, focus_restore is owed
var _speech_kind := ""          # answer | reprompt | farewell | info
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	args = FiloArgs.parse(OS.get_cmdline_user_args())
	cfg = FiloConfig.load_default(args)
	FiloLog.verbose = bool(cfg.get_value("verbose", false))
	FiloLog.info("Filo Phase 0 starting (Godot %s)" % Engine.get_version_info().string)
	FiloLog.info("Config: " + (cfg.source_path if cfg.source_path != "" else "defaults (no config.json found at " + FiloConfig.project_root() + ")"))
	if cfg.dotenv_path != "":
		FiloLog.info("Env file: " + cfg.dotenv_path)

	win_info = OverlayWindow.setup(get_window(), cfg)
	_build_ui()
	_setup_timers()

	profiles_dir = cfg.resolve_path(str(cfg.get_value("profiles_dir", "profiles")))
	_load_profile(str(cfg.get_value("default_profile", "sekiro")))

	speaker = Speaker.new()
	speaker.name = "Speaker"
	add_child(speaker)
	speaker.setup(cfg)
	speaker.started.connect(_on_speaker_started)
	speaker.boundary.connect(_on_speaker_boundary)
	speaker.finished.connect(_on_speaker_finished)
	speaker.cancelled.connect(_on_speaker_cancelled)
	speaker.mouth_level.connect(func(v: float) -> void: mascot.animator.set_mouth_level(v))
	controls.sound_button.set_muted(not speaker.enabled)
	controls.sound_button.pressed.connect(_on_sound_button_pressed)
	controls.mode_button.pressed.connect(_on_mode_button_pressed)
	controls.mic_button.pressed.connect(_on_mic_button_pressed)
	controls.type_button.pressed.connect(_on_type_button_pressed)
	controls.mic_button.set_hotkey_label(cfg.hotkey_label("hotkey_mute") if _mute_hotkey_enabled() else "")
	_rng.randomize()

	pipeline = AnswerPipeline.new()
	pipeline.name = "AnswerPipeline"
	add_child(pipeline)
	pipeline.setup(cfg, profile)
	FiloLog.info("LLM: " + pipeline.llm_label())

	mascot.animator.wake_finished.connect(_on_wake_finished)
	mascot.animator.sleep_finished.connect(_on_sleep_finished)
	mascot.animator.error_finished.connect(_on_error_finished)
	mascot.animator.set_glint(bool(cfg.get_value("screen_reading.enabled", false)))

	var showcase_mode := args.has("showcase")
	if not showcase_mode and bool(cfg.get_value("helper.enabled", true)):
		_start_helper()
	elif not showcase_mode:
		FiloLog.info("Helper disabled: the overlay stays clickable — click the mascot area, then press Space to type a question, Esc to dismiss")
		_fallback_interactive = true
		OverlayWindow.set_passthrough(get_window(), false)
	_set_fps(false)

	if args.has("list_voices"):
		for v in DisplayServer.tts_get_voices():
			print("voice: %s | %s | %s" % [v.get("name", ""), v.get("language", ""), v.get("id", "")])
		quit()
		return
	if args.has("quit_after"):
		var t := float(str(args["quit_after"]))
		if t > 0.0:
			get_tree().create_timer(t).timeout.connect(quit)

	if showcase_mode:
		showcase = Showcase.new()
		showcase.name = "Showcase"
		add_child(showcase)
		showcase.run(self, str(args.get("capture_dir", "")))
	elif args.has("ask"):
		_scripted = true
		call_deferred("_run_scripted_question", str(args["ask"]))
	elif bool(cfg.get_value("behavior.greet_on_launch", true)):
		call_deferred("_greet")


func _build_ui() -> void:
	var pts: Vector2 = win_info.size_pts
	mascot = Mascot.new()
	mascot.name = "Mascot"
	mascot.configure(cfg, float(win_info.scale))
	add_child(mascot)
	mascot.position = Vector2(pts.x - mascot.display_pts - 8.0, pts.y - mascot.display_pts - 8.0)

	bubble = Bubble.new()
	bubble.name = "Bubble"
	add_child(bubble)

	input_panel = InputPanel.new()
	input_panel.name = "InputPanel"
	add_child(input_panel)
	input_panel.submitted.connect(_on_typed_submitted)
	input_panel.closed.connect(_on_input_closed)

	controls = ControlBar.new()
	add_child(controls)

	hint = Label.new()
	hint.name = "Hint"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", HINT_COLOR)
	hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	hint.add_theme_constant_override("shadow_offset_x", 1)
	hint.add_theme_constant_override("shadow_offset_y", 1)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = MOUSE_FILTER_IGNORE
	hint.text = _activation_hint()
	hint.position = Vector2(mascot.position.x - 200.0, mascot.position.y + mascot.display_pts * 0.87)
	hint.size = Vector2(mascot.display_pts + 200.0, 18.0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.modulate.a = 0.0
	add_child(hint)


func _setup_timers() -> void:
	idle_timer = _make_timer("IdleTimer", true, _on_idle_timeout)
	linger_timer = _make_timer("LingerTimer", true, _on_linger_timeout)
	final_timer = _make_timer("FinalTimer", true, _on_final_timeout)
	speech_watchdog = _make_timer("SpeechWatchdog", true, _on_speech_watchdog)
	apps_timer = _make_timer("AppsTimer", false, _on_apps_tick)
	helper_watchdog = _make_timer("HelperWatchdog", true, _on_helper_watchdog)


func _make_timer(timer_name: String, one_shot: bool, cb: Callable) -> Timer:
	var t := Timer.new()
	t.name = timer_name
	t.one_shot = one_shot
	add_child(t)
	t.timeout.connect(cb)
	return t


func _process(_delta: float) -> void:
	var center := mascot.position + mascot.cube_center_local()
	var right := mascot.position.x + mascot.display_pts * 0.17
	var bottom := center.y + mascot.display_pts * 0.2
	if input_panel.visible:
		input_panel.position = Vector2(right - input_panel.size.x, bottom - input_panel.size.y)
		bottom = input_panel.position.y - 8.0
	# the bubble places itself from these anchors in its own _process, right after
	# it measures its panel, so its position never lags a frame behind its size
	bubble.tail_anchor_x = right - 12.0
	bubble.bottom_anchor_y = bottom
	bubble.tail_target_y = center.y
	_sync_scale()
	_layout_controls()
	_apply_window_mode()
	if _mute_deadline > 0.0 and Time.get_ticks_msec() / 1000.0 > _mute_deadline:
		_mute_deadline = 0.0
		if bridge != null and helper_connected and not mic_mute_confirmed:
			FiloLog.warn("The helper did not confirm the microphone %s request" % ("mute" if mic_muted else "unmute"))


# ------------------------------------------------------------------ helper

func _start_helper() -> void:
	bridge = HelperBridge.new()
	bridge.name = "HelperBridge"
	add_child(bridge)
	bridge.connected.connect(_on_helper_connected)
	bridge.disconnected.connect(_on_helper_disconnected)
	bridge.helper_ready.connect(_on_helper_ready)
	bridge.hotkey_down.connect(_on_hotkey_down)
	bridge.hotkey_up.connect(_on_hotkey_up)
	bridge.tap.connect(_on_tap)
	bridge.wake_word.connect(_on_wake_word)
	bridge.listen_timeout.connect(_on_listen_timeout)
	bridge.bye.connect(_on_bye)
	bridge.partial_transcript.connect(_on_partial)
	bridge.final_transcript.connect(_on_final)
	bridge.level.connect(func(v: float) -> void: mascot.animator.set_level(v))
	bridge.apps.connect(_on_apps)
	bridge.helper_error.connect(_on_helper_error)
	bridge.mute_state.connect(_on_mute_state)
	var port := int(cfg.get_value("helper.port", 47821))
	if bridge.start_listening(port) != OK:
		call_deferred("_notice", "I couldn't open port %d for the hotkey helper. Is another Filo running?" % port)
		return
	var path := cfg.resolve_path(str(cfg.get_value("helper.path", "")))
	var extra := FiloArgs.split_shell(str(cfg.get_value("helper.args", "")))
	var wake_phrase := str(cfg.get_value("wake_word.phrase", "hey filo")) if bool(cfg.get_value("wake_word.enabled", true)) else ""
	var ok := bridge.launch(
		path, extra,
		str(cfg.get_value("hotkey.key", "space")), cfg.get_value("hotkey.modifiers", []),
		bool(cfg.get_value("helper.allow_server_speech", false)), str(cfg.get_value("helper.locale", "en-US")),
		wake_phrase, int(cfg.get_value("wake_word.silence_ms", 1500)), _helper_extra_flags())
	if not ok:
		call_deferred("_notice", "The hotkey helper isn't built yet — run scripts/build_helper.sh. Until then, click me and press Space to type.")
		_fallback_interactive = true
		OverlayWindow.set_passthrough(get_window(), false)
		return
	helper_watchdog.start(8.0)


func _helper_extra_flags() -> PackedStringArray:
	var flags := PackedStringArray(["--parent-pid", str(OS.get_process_id())])
	if _mute_hotkey_enabled():
		flags.append_array(PackedStringArray(["--mute-key", str(cfg.get_value("hotkey_mute.key", "m")), "--mute-mods", ",".join(PackedStringArray(cfg.get_value("hotkey_mute.modifiers", [])))]))
	return flags


func _mute_hotkey_enabled() -> bool:
	return str(cfg.get_value("hotkey_mute.key", "")).strip_edges() != ""


func _on_helper_connected() -> void:
	helper_connected = true
	helper_watchdog.stop()
	apps_timer.start(5.0)
	if mic_muted:
		bridge.send({"cmd": "set_mute", "muted": true})


func _on_helper_disconnected() -> void:
	helper_connected = false
	apps_timer.stop()
	if not _quitting:
		_notice("The hotkey helper stopped. Restart Filo to get the hotkey back.")


func _on_helper_ready(info: Dictionary) -> void:
	FiloLog.info("Helper ready: " + JSON.stringify(info))
	if args.has("test_hotkey"):
		_run_hotkey_test()
	if not bool(info.get("hotkey_registered", true)):
		_notice("I couldn't register the hotkey %s — another app may be using it. Change it under \"hotkey\" in config.json." % cfg.hotkey_label())


func _on_helper_watchdog() -> void:
	if not helper_connected and not _quitting:
		_notice("The hotkey helper didn't connect. Try scripts/build_helper.sh, then restart Filo.")
		_fallback_interactive = true
		OverlayWindow.set_passthrough(get_window(), false)


func _on_helper_error(code: String, message: String) -> void:
	FiloLog.warn("Helper error [%s]: %s" % [code, message])
	match code:
		"retry", "muted":
			_notice(message)
		"speech_denied", "mic_denied", "speech_unavailable", "no_input_device", "audio_engine", "recognition":
			_pending_final = false
			_notice(message)
			if app_state == AppState.LISTENING:
				_set_state(AppState.IDLE)
		_:
			_notice(message)


func _on_apps_tick() -> void:
	if bridge:
		bridge.send({"cmd": "list_apps"})


func _on_apps(list: Array) -> void:
	# Detect a running game by app name and switch to its profile.
	var names := PackedStringArray()
	for a in list:
		if typeof(a) == TYPE_DICTIONARY:
			names.append(str(a.get("name", "")))
	for pid in GameProfile.list_profiles(profiles_dir):
		if not _profile_cache.has(pid):
			_profile_cache[pid] = GameProfile.load_from(profiles_dir, pid)
		var p: GameProfile = _profile_cache[pid]
		for n in names:
			if p.matches_app(n):
				if profile.id != pid:
					FiloLog.info("Detected running game '%s' -> profile %s" % [n, pid])
					_load_profile(pid)
					pipeline.set_profile(profile)
					if app_state != AppState.ASLEEP:
						_notice("Switched to %s." % profile.name)
				return


# ------------------------------------------------------------- interactions

func _on_hotkey_down() -> void:
	_last_partial = ""
	_pending_final = false
	_has_queued_final = false
	_followup = false
	final_timer.stop()
	_press_origin = app_state
	_press_origin_valid = true
	match app_state:
		AppState.ASLEEP, AppState.SLEEPING:
			_wake(AppState.LISTENING)
		AppState.WAKING:
			_wake_target = AppState.LISTENING
		AppState.TYPING:
			input_panel.close()
			_enter_listening()
		AppState.ANSWERING:
			speaker.stop()
			_enter_listening()
		AppState.THINKING:
			_answer_token += 1
			_enter_listening()
		_:
			_enter_listening()


## The helper heard the wake phrase; it keeps listening and sends the question as `final`.
func _on_wake_word(_phrase: String) -> void:
	FiloLog.info("Wake word heard")
	_last_partial = ""
	_pending_final = true
	_has_queued_final = false
	final_timer.start(22.0)
	_press_origin = app_state
	match app_state:
		AppState.ASLEEP, AppState.SLEEPING:
			_wake(AppState.LISTENING)
		AppState.WAKING:
			_wake_target = AppState.LISTENING
		AppState.TYPING:
			input_panel.close()
			_enter_listening()
		AppState.ANSWERING:
			speaker.stop()
			_enter_listening()
		AppState.THINKING:
			_answer_token += 1
			_enter_listening()
		AppState.LISTENING:
			pass
		_:
			_enter_listening()


func _on_hotkey_up(_duration_ms: int) -> void:
	if app_state in [AppState.LISTENING, AppState.WAKING]:
		_pending_final = true
		final_timer.start(4.0)


func _on_tap() -> void:
	# The helper reports hotkey_down first (we may already be LISTENING), then
	# decides it was a tap; act on the state the press started from. A tap while
	# Filo is awake dismisses it; a tap while asleep opens the typed question.
	var origin := _press_origin if (_press_origin_valid and app_state == AppState.LISTENING) else app_state
	_press_origin = AppState.ASLEEP
	_press_origin_valid = false
	match origin:
		AppState.ASLEEP, AppState.SLEEPING:
			if app_state == AppState.LISTENING:
				_open_typing()
			else:
				_wake(AppState.TYPING)
		AppState.WAKING:
			_wake_target = AppState.TYPING
		_:
			_sleep()


func _on_partial(text: String) -> void:
	_last_partial = text
	if app_state == AppState.LISTENING:
		bubble.show_listening(text)


func _on_final(text: String) -> void:
	_pending_final = false
	final_timer.stop()
	if app_state == AppState.WAKING:
		_queued_final = text
		_has_queued_final = true
		return
	if app_state != AppState.LISTENING:
		return
	_handle_final(text)


## Follow-up listening ended in silence: stay visible, go idle, wake word still works.
func _on_listen_timeout() -> void:
	if app_state == AppState.LISTENING and _followup:
		_followup = false
		_set_state(AppState.IDLE)
		bubble.show_info("I'm here if you need more — %s, or tap %s to dismiss me." % [_activation_sentence().to_lower(), cfg.hotkey_label()])


## "bye filo" was heard: say goodbye and spin out.
func _on_bye() -> void:
	if app_state in [AppState.ASLEEP, AppState.SLEEPING]:
		return
	_farewell()


func _farewell() -> void:
	FiloLog.info("Bye heard")
	_answer_token += 1
	_pending_final = false
	_followup = false
	if bridge:
		bridge.send({"cmd": "listen_stop"})
	if input_panel.is_open():
		input_panel.close()
	speaker.stop()
	var phrase := _pick(cfg.get_value("behavior.farewell_phrases", ["Bye!"]), "Bye!")
	app_state = AppState.ANSWERING
	mascot.animator.play_farewell()
	bubble.show_info(phrase)
	_speak(phrase, "farewell")


func _is_bye(text: String) -> bool:
	var t := text.to_lower().strip_edges()
	if t == "":
		return false
	var bye_phrase := str(cfg.get_value("wake_word.bye_phrase", "bye filo")).to_lower()
	return t.contains(bye_phrase) or (t.length() < 24 and (t.begins_with("bye") or t.begins_with("goodbye")) and t.contains("filo"))


func _on_final_timeout() -> void:
	if _pending_final:
		_pending_final = false
		if app_state == AppState.LISTENING:
			_handle_final(_last_partial)


func _handle_final(text: String) -> void:
	var q := text.strip_edges()
	var was_followup := _followup
	_followup = false
	if _is_bye(q):
		_farewell()
		return
	if q == "":
		if was_followup:
			_set_state(AppState.IDLE)
			bubble.show_info("I'm here if you need more — %s." % _activation_sentence().to_lower())
		else:
			bubble.show_info("I didn't catch that — %s." % ("say “%s” again or hold %s" % [str(cfg.get_value("wake_word.phrase", "hey filo")), cfg.hotkey_label()] if _wake_enabled() else "hold %s and try again" % cfg.hotkey_label()))
			_set_state(AppState.IDLE)
		return
	mascot.animator.nod()
	_ask(q)


func _on_typed_submitted(text: String) -> void:
	input_panel.close()
	var was_followup := _followup
	_followup = false
	if was_followup and _is_bye(text):
		_farewell()
		return
	var lower := text.to_lower()
	if lower == "/glint":
		var on := not mascot.animator.glint
		mascot.animator.set_glint(on)
		bubble.show_info("Screen-reading cue preview %s. (Screen reading itself is off in Phase 0.)" % ("on" if on else "off"))
		return
	if lower == "/sleep":
		_sleep()
		return
	if lower == "/quit":
		quit()
		return
	if lower == "/help":
		bubble.show_info("%s, or tap %s to type. Commands: /glint, /sleep, /quit, /help." % [_activation_sentence(), cfg.hotkey_label()])
		return
	_ask(text, "typed")


func _on_input_closed() -> void:
	controls.type_button.set_active(false)
	_end_typing_focus()
	_apply_window_mode()
	if app_state == AppState.TYPING:
		_set_state(AppState.IDLE)


func _unhandled_input(event: InputEvent) -> void:
	# Local fallback when the helper is not available: the overlay is clickable
	# and Space / Escape act as tap / dismiss.
	if bridge != null and helper_connected:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and app_state in [AppState.ASLEEP, AppState.IDLE, AppState.ANSWERING, AppState.THINKING]:
			get_viewport().set_input_as_handled()
			_on_tap()
		elif event.keycode == KEY_ESCAPE and app_state != AppState.ASLEEP:
			get_viewport().set_input_as_handled()
			_sleep()


# ------------------------------------------------------------ state machine

func _wake(target: int) -> void:
	_wake_target = target
	if app_state == AppState.WAKING:
		return
	app_state = AppState.WAKING
	_set_fps(true)
	idle_timer.stop()
	linger_timer.stop()
	mascot.animator.wake()


func _on_wake_finished() -> void:
	if app_state != AppState.WAKING:
		return
	_show_hint()
	match _wake_target:
		AppState.LISTENING:
			_enter_listening()
		AppState.TYPING:
			_open_typing()
		_:
			_set_state(AppState.IDLE)
	if _has_queued_final:
		_has_queued_final = false
		if app_state == AppState.LISTENING:
			_handle_final(_queued_final)


func _enter_listening() -> void:
	_set_state(AppState.LISTENING)
	bubble.show_listening(_last_partial)


func _ask(question: String, source: String = "voice") -> void:
	question_asked.emit(question, source)
	_set_state(AppState.THINKING)
	bubble.show_thinking(question)
	_answer_token += 1
	var token := _answer_token
	FiloLog.info("QUESTION: " + question)
	var result: Dictionary = await pipeline.ask(question)
	if token != _answer_token or app_state != AppState.THINKING:
		FiloLog.debug("Answer discarded (superseded)")
		return
	if not bool(result.get("ok", false)):
		FiloLog.warn("ANSWER FAILED: " + str(result.get("error", "")))
		_show_error(str(result.get("error", "Something went wrong.")))
		return
	if str(result.get("route", "")) == "command":
		_handle_command(result)
		return
	FiloLog.info("ANSWER (%s%s): %s" % [str(result.get("model", "")), ", web" if result.get("used_web", false) else "", result.text])
	for s in result.sources:
		FiloLog.info("SOURCE: %s — %s" % [s.title, s.url])
	mascot.animator.register_turn()
	_had_first_answer = true
	_set_state(AppState.ANSWERING)
	bubble.show_answer(question, result.text, result.sources, bool(result.get("used_web", false)))
	_speak(result.spoken, "answer")


## Voice commands recognised by the pipeline (no model, no tools): stop, mute, unmute, repeat.
func _handle_command(result: Dictionary) -> void:
	var cmd := str(result.get("command", ""))
	FiloLog.info("COMMAND: " + cmd)
	match cmd:
		"stop":
			speaker.stop()
			bubble.show_info("Okay.")
			_set_state(AppState.IDLE)
		"mute", "unmute":
			var on := cmd == "mute"
			speaker.set_muted(on)
			controls.sound_button.set_muted(on)
			bubble.show_info(str(result.text))
			_set_state(AppState.IDLE)
			if not on:
				_speak(str(result.spoken), "info")
		"repeat":
			_set_state(AppState.ANSWERING)
			bubble.show_answer("", str(result.text), [], false)
			_speak(str(result.spoken), "answer")
		_:
			_set_state(AppState.IDLE)
	if _scripted and cmd != "repeat":
		_finish_scripted()


## After an answer: a short spoken "anything else?" then open listening.
func _reprompt() -> void:
	var phrase := _pick(cfg.get_value("behavior.reprompt_phrases", ["Anything else?"]), "Anything else?")
	FiloLog.info("Reprompt: " + phrase)
	_speech_kind = "reprompt"
	app_state = AppState.ANSWERING
	mascot.animator.react_after_answer()
	bubble.show_followup(phrase, str(cfg.get_value("wake_word.bye_phrase", "bye filo")), cfg.hotkey_label())
	_speak(phrase, "reprompt")


func _open_followup_listening() -> void:
	if bridge == null or not helper_connected:
		_set_state(AppState.IDLE)
		return
	_followup = true
	_last_partial = ""
	_pending_final = true
	var seconds := float(cfg.get_value("behavior.followup_listen_seconds", 30))
	final_timer.start(seconds + 25.0)
	bridge.send({"cmd": "listen_open", "timeout_ms": int(seconds * 1000.0)})
	_set_state(AppState.LISTENING)
	bubble.show_listening("", true)


## Follow-up in text mode: an empty text field opens instead of the mic —
## the same box the hotkey-tap flow uses, pre-armed as a follow-up so
## conversation history keeps flowing exactly as it does in voice mode.
func _open_followup_typing() -> void:
	_followup = true
	_begin_typing_focus()
	_set_state(AppState.TYPING)
	input_panel.open()
	_focus_input()


## Speaks `text` and arms a safety-net timer sized to the text's length: if
## Speaker never reports back (a stuck TTS provider, a hung request, or any
## failure mode we didn't foresee), the watchdog forces the same completion
## path a normal finish would take, so the app can never get stuck answering
## and the mic is never left permanently unavailable.
func _speak(text: String, kind: String) -> void:
	_speech_kind = kind
	var seconds := clampf(text.length() * 0.16, 8.0, 60.0)
	speech_watchdog.start(seconds)
	speaker.speak(text)


func _on_speech_watchdog() -> void:
	if speaker.is_speaking():
		FiloLog.warn("Speech watchdog: TTS took too long, forcing it to finish")
		speaker.force_finish()


func _pick(options, fallback: String) -> String:
	if typeof(options) == TYPE_ARRAY and options.size() > 0:
		return str(options[_rng.randi_range(0, options.size() - 1)])
	return fallback


func _show_error(message: String) -> void:
	bubble.show_error(message)
	mascot.animator.play_error()
	_set_state(AppState.IDLE, false)
	linger_timer.start(float(cfg.get_value("behavior.answer_linger", 12.0)))
	if _scripted:
		_finish_scripted()


func _on_error_finished() -> void:
	pass


func _set_state(s: int, drive_animator: bool = true) -> void:
	app_state = s
	FiloLog.debug("state -> " + AppState.keys()[s] + (" (follow-up)" if s == AppState.LISTENING and _followup else ""))
	match s:
		AppState.IDLE:
			if drive_animator:
				mascot.animator.set_state(MascotAnimator.State.IDLE)
			var idle_timeout := float(cfg.get_value("behavior.idle_timeout", 0.0))
			if idle_timeout > 0.0:
				idle_timer.start(idle_timeout)
		AppState.LISTENING:
			idle_timer.stop()
			linger_timer.stop()
			mascot.animator.set_state(MascotAnimator.State.LISTENING)
		AppState.THINKING:
			idle_timer.stop()
			linger_timer.stop()
			mascot.animator.set_state(MascotAnimator.State.THINKING)
		AppState.ANSWERING:
			idle_timer.stop()
			linger_timer.stop()
			mascot.animator.set_state(MascotAnimator.State.ANSWERING)
		AppState.TYPING:
			idle_timer.stop()
			mascot.animator.set_state(MascotAnimator.State.IDLE)


func _sleep() -> void:
	if app_state in [AppState.ASLEEP, AppState.SLEEPING]:
		return
	_answer_token += 1
	_pending_final = false
	_followup = false
	_followup_mode = "voice"
	_had_first_answer = false
	controls.mode_button.set_mode("voice")
	_speech_kind = ""
	if bridge:
		bridge.send({"cmd": "listen_stop"})
	speaker.stop()
	pipeline.clear_history()
	if input_panel.is_open():
		input_panel.close()
	bubble.hide_bubble()
	_hide_hint()
	idle_timer.stop()
	linger_timer.stop()
	app_state = AppState.SLEEPING
	FiloLog.debug("state -> SLEEPING")
	mascot.animator.sleep()


func _on_sleep_finished() -> void:
	if app_state != AppState.SLEEPING:
		return
	app_state = AppState.ASLEEP
	FiloLog.debug("state -> ASLEEP")
	_set_fps(false)
	if _quit_after_sleep:
		quit()


func _open_typing() -> void:
	_begin_typing_focus()
	_set_state(AppState.TYPING)
	input_panel.open()
	_focus_input()
	if bubble.mode == Bubble.Mode.HIDDEN:
		bubble.show_info("Type your question, then press Enter.")


func _greet() -> void:
	_wake(AppState.IDLE)
	await mascot.animator.wake_finished
	if app_state != AppState.IDLE:
		return
	var msg := "Hi, I'm Filo, a portable wiki guide for any game — right now I'm loaded up on %s. %s — or tap %s to type." % [profile.name if profile else "this game", _activation_sentence(), cfg.hotkey_label()]
	if bridge == null:
		msg = "Hi, I'm Filo, a portable wiki guide for any game. The hotkey helper is off, so click me and press Space to type a question."
	bubble.show_info(msg)
	idle_timer.start(float(cfg.get_value("behavior.greet_linger", 8.0)))


func _run_scripted_question(question: String) -> void:
	_wake(AppState.IDLE)
	await mascot.animator.wake_finished
	if app_state != AppState.IDLE:
		return
	_ask(question)


## --test-hotkey: asks the real helper to simulate a 1.2 s hold, then a tap,
## which exercises the whole hotkey -> bridge -> state machine path without a mic.
func _run_hotkey_test() -> void:
	await get_tree().create_timer(1.0).timeout
	FiloLog.info("Hotkey test: simulated hold")
	bridge.send({"cmd": "simulate_hotkey", "pressed": true})
	await get_tree().create_timer(1.2).timeout
	bridge.send({"cmd": "simulate_hotkey", "pressed": false})
	await get_tree().create_timer(3.0).timeout
	FiloLog.info("Hotkey test: simulated tap")
	bridge.send({"cmd": "simulate_hotkey", "pressed": true})
	await get_tree().create_timer(0.1).timeout
	bridge.send({"cmd": "simulate_hotkey", "pressed": false})


func _finish_scripted() -> void:
	_scripted = false
	await get_tree().create_timer(1.5).timeout
	_quit_after_sleep = true
	_sleep()


func _notice(message: String) -> void:
	FiloLog.warn("Notice: " + message)
	if app_state == AppState.ASLEEP:
		_wake(AppState.IDLE)
		await mascot.animator.wake_finished
	if app_state in [AppState.IDLE, AppState.TYPING, AppState.ANSWERING]:
		bubble.show_info(message)
		linger_timer.start(float(cfg.get_value("behavior.answer_linger", 12.0)))


# ---------------------------------------------------------------- controls

## Mute button: takes effect immediately. If Filo is mid-answer, it stops
## there (the text stays fully visible) rather than finishing silently and
## then auto-reprompting into dead air — the same thing an interrupting tap
## already does, just without opening the mic afterwards.
func _on_sound_button_pressed() -> void:
	var now_muted := not speaker.user_muted
	speaker.set_muted(now_muted)
	controls.sound_button.set_muted(now_muted)
	FiloLog.info("Sound " + ("muted" if now_muted else "unmuted"))
	if now_muted and speaker.is_speaking():
		speaker.stop()
		bubble.reveal_all()
		if app_state == AppState.ANSWERING:
			_set_state(AppState.IDLE)
			var linger := float(cfg.get_value("behavior.answer_linger", 0.0))
			if linger > 0.0:
				linger_timer.start(linger)


## Voice/text toggle for follow-ups. Only ever shown once voice follow-ups
## are actually possible (bridge connected), so there's never a state where
## it's visible but does nothing. If a follow-up is active right now, the
## switch takes effect immediately instead of waiting for the next question.
func _on_mode_button_pressed() -> void:
	_followup_mode = "text" if _followup_mode == "voice" else "voice"
	controls.mode_button.set_mode(_followup_mode)
	FiloLog.info("Follow-up mode: " + _followup_mode)
	if _followup and app_state == AppState.LISTENING:
		if bridge:
			bridge.send({"cmd": "listen_stop"})
		if _followup_mode == "text":
			_open_followup_typing()
		else:
			_open_followup_listening()
	elif _followup and app_state == AppState.TYPING and input_panel.is_open():
		input_panel.close()
		if _followup_mode == "voice":
			_open_followup_listening()


## The mic mute button (or the mute hotkey in the helper). The state is shown at once and sent to
## the helper, which stops listening and confirms with a `mute_state` event.
func _on_mic_button_pressed() -> void:
	set_mic_muted(not mic_muted, "button")


func set_mic_muted(muted: bool, source: String) -> void:
	mic_muted = muted
	mic_mute_confirmed = false
	controls.mic_button.set_muted(muted)
	FiloLog.info("Microphone %s (%s)" % ["muted" if muted else "unmuted", source])
	if muted:
		_pending_final = false
		_followup = false
		final_timer.stop()
		if app_state == AppState.LISTENING:
			_set_state(AppState.IDLE)
	if bridge != null and helper_connected:
		bridge.send({"cmd": "set_mute", "muted": muted})
		_mute_deadline = Time.get_ticks_msec() / 1000.0 + 2.0
	else:
		FiloLog.warn("No helper connected: the mute is only visual until it connects")
	if app_state != AppState.ASLEEP:
		var hotkey := " or press %s" % cfg.hotkey_label("hotkey_mute") if _mute_hotkey_enabled() else ""
		bubble.show_info("Microphone muted. Click the mic again%s to unmute." % hotkey if muted else "Microphone is back on.")


## The helper's confirmation of set_mute, or its own report when the mute hotkey was pressed.
func _on_mute_state(muted: bool, source: String) -> void:
	FiloLog.info("Helper reports microphone %s (%s)" % ["muted" if muted else "unmuted", source])
	if source == "hotkey":
		set_mic_muted(muted, "hotkey")   # mirror the state (the command it sends back is idempotent)
		return
	mic_mute_confirmed = muted == mic_muted
	_mute_deadline = 0.0


## The type button: opens the question box (waking Filo first when it is asleep) or closes it.
func _on_type_button_pressed() -> void:
	match app_state:
		AppState.ASLEEP, AppState.SLEEPING:
			_wake(AppState.TYPING)
		AppState.WAKING:
			_wake_target = AppState.TYPING
		AppState.TYPING:
			input_panel.close()
		_:
			_answer_token += 1
			speaker.stop()
			if bridge:
				bridge.send({"cmd": "listen_stop"})
			_pending_final = false
			_followup = false
			_open_typing()


## Typing needs the keyboard: remember what had focus (the game), then take it. The helper gives
## it back in _end_typing_focus.
func _begin_typing_focus() -> void:
	if bridge != null and helper_connected and not _focus_saved:
		bridge.send({"cmd": "focus_save"})
		_focus_saved = true
	controls.type_button.set_active(true)


## The box is open: make the window interactive + focusable, bring it to the front, focus the field.
func _focus_input() -> void:
	_apply_window_mode()
	DisplayServer.window_move_to_foreground()
	input_panel.line.grab_focus()


func _end_typing_focus() -> void:
	if _focus_saved and bridge != null:
		bridge.send({"cmd": "focus_restore"})
	_focus_saved = false


# ----------------------------------------------------- click-through + control layout

## Screen scale of the display the window is on (2.0 on Retina).
func _current_scale() -> float:
	var sc := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	return sc if sc > 0.0 else 1.0


## The window moved to a display with another backing scale (or the resolution changed): keep the
## same size in points and re-derive everything that depends on the scale.
func _sync_scale() -> void:
	var sc := _current_scale()
	if not is_equal_approx(sc, float(win_info.scale)):
		apply_scale(sc)


func apply_scale(sc: float) -> void:
	FiloLog.info("Display scale changed %.1f -> %.1f: resizing the overlay" % [float(win_info.scale), sc])
	win_info = OverlayWindow.apply_scale(get_window(), cfg, sc)


## Places the control bar left of the cube, under the bubble, and keeps it inside the window.
func _layout_controls() -> void:
	var pts := Vector2(get_window().size) / maxf(float(win_info.scale), 0.01)
	var right := mascot.position.x + mascot.display_pts * 0.17 - 12.0
	var want := Vector2(right - controls.size.x, pts.y - controls.size.y - 10.0)
	want.x = clampf(want.x, 4.0, maxf(4.0, pts.x - controls.size.x - 4.0))
	want.y = clampf(want.y, 4.0, maxf(4.0, pts.y - controls.size.y - 4.0))
	if controls.position != want:
		controls.position = want


## Rects (window-local points) that must take clicks right now.
func interactive_rects() -> Array:
	return controls.interactive_rects()


## The window is click-through everywhere except over the controls, so the game underneath stays
## usable. Each frame the cursor's screen position decides whether the whole window ignores the
## mouse (see ClickRegion for why this replaces the pixel/point-mismatched polygon). Typing, and
## the no-helper fallback, need the whole window (and keyboard focus) instead.
func _apply_window_mode() -> void:
	var window := get_window()
	var typing := input_panel != null and input_panel.is_open()
	var whole := _fallback_interactive or typing
	var want_pass := false
	if not whole:
		want_pass = ClickRegion.passthrough_at(Vector2(DisplayServer.mouse_get_position()), Vector2(window.position), float(win_info.scale), interactive_rects())
	window_state = {"passthrough": want_pass, "unfocusable": not whole}   # what we ask the OS for (tests read this)
	if window.mouse_passthrough_polygon.size() > 0:
		window.mouse_passthrough_polygon = PackedVector2Array()
	if window.mouse_passthrough != want_pass:
		window.mouse_passthrough = want_pass
	if window.unfocusable != (not whole):
		window.unfocusable = not whole


## A rect as a 4-point clockwise polygon in window-local points. The window no longer uses
## Window.mouse_passthrough_polygon (its pixel/point mismatch left the buttons unclickable on
## Retina, see ClickRegion); kept as a small geometry utility.
static func rect_to_polygon(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y),
	])


# ------------------------------------------------------------- speaker hooks

func _on_speaker_started(_id: int) -> void:
	if bridge:
		bridge.send({"cmd": "wake_pause"})   # don't let Filo wake itself up
	if app_state == AppState.ANSWERING:
		mascot.animator.talk_pulse()


func _on_speaker_boundary(pos: int, _id: int) -> void:
	if app_state == AppState.ANSWERING:
		mascot.animator.talk_pulse()
		bubble.reveal_to(pos)


func _on_speaker_finished(_id: int) -> void:
	speech_watchdog.stop()
	if bridge:
		bridge.send({"cmd": "wake_resume"})
	var kind := _speech_kind
	_speech_kind = ""
	if kind == "farewell":
		_sleep()
		return
	if app_state != AppState.ANSWERING:
		return
	if kind == "reprompt":
		if _followup_mode == "text":
			_open_followup_typing()
		else:
			_open_followup_listening()
		return
	bubble.reveal_all()
	if _scripted:
		_set_state(AppState.IDLE)
		_finish_scripted()
		return
	if bool(cfg.get_value("behavior.reprompt", true)) and bridge != null and helper_connected:
		_reprompt()
	else:
		_set_state(AppState.IDLE)
		var linger := float(cfg.get_value("behavior.answer_linger", 0.0))
		if linger > 0.0:
			linger_timer.start(linger)


func _on_speaker_cancelled(_id: int) -> void:
	speech_watchdog.stop()
	if bridge:
		bridge.send({"cmd": "wake_resume"})
	bubble.reveal_all()


# ------------------------------------------------------------------- timers

func _on_idle_timeout() -> void:
	if app_state == AppState.IDLE:
		_sleep()


func _on_linger_timeout() -> void:
	if app_state in [AppState.IDLE, AppState.TYPING]:
		bubble.hide_bubble()


# -------------------------------------------------------------------- misc

func _load_profile(profile_id: String) -> void:
	if _profile_cache.has(profile_id):
		profile = _profile_cache[profile_id]
	else:
		profile = GameProfile.load_from(profiles_dir, profile_id)
		_profile_cache[profile_id] = profile
	if profile.load_error != "":
		FiloLog.warn("Profile problem: " + profile.load_error)


func _wake_enabled() -> bool:
	return bridge != null and bool(cfg.get_value("wake_word.enabled", true))


func _activation_hint() -> String:
	if _wake_enabled():
		return "say “%s” · hold %s · say “%s” or tap %s to dismiss" % [str(cfg.get_value("wake_word.phrase", "hey filo")), cfg.hotkey_label(), str(cfg.get_value("wake_word.bye_phrase", "bye filo")), cfg.hotkey_label()]
	return "hold %s · talk     tap %s · dismiss" % [cfg.hotkey_label(), cfg.hotkey_label()]


func _activation_sentence() -> String:
	if _wake_enabled():
		return "Say “%s” or hold %s and ask me something" % [str(cfg.get_value("wake_word.phrase", "hey filo")), cfg.hotkey_label()]
	return "Hold %s and ask me something" % cfg.hotkey_label()


func _show_hint() -> void:
	if hint_tween and hint_tween.is_valid():
		hint_tween.kill()
	hint_tween = create_tween()
	hint_tween.tween_property(hint, "modulate:a", 1.0, 0.3)
	hint_tween.tween_interval(5.0)
	hint_tween.tween_property(hint, "modulate:a", 0.0, 0.6)


func _hide_hint() -> void:
	if hint_tween and hint_tween.is_valid():
		hint_tween.kill()
	hint.modulate.a = 0.0


func _set_fps(awake: bool) -> void:
	Engine.max_fps = 60 if awake else 15


func showcase_done() -> void:
	if not args.has("stay"):
		quit()


func quit() -> void:
	if _quitting:
		return
	_quitting = true
	FiloLog.info("Filo quitting")
	if bridge:
		bridge.shutdown()
	if speaker:
		speaker.shutdown()
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit()
