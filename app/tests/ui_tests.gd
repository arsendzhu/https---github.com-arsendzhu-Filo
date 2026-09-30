extends SceneTree
## Scene-level UI + IPC tests: the real main scene, a real helper process (scripts/fake_helper.py --idle)
## and the real TCP bridge between them. Run by scripts/test.sh:
##
##   FILO_UI_TEST_LOG=/tmp/cmds.jsonl godot --headless --path app -s tests/ui_tests.gd -- \
##       --helper-cmd python3 --helper-args "scripts/fake_helper.py --idle --log-commands /tmp/cmds.jsonl" \
##       --no-greet --mute --port 47890 --tts-provider system
##
## The fake helper writes every command it receives to the log, so "the message arrived on the other
## side of the socket" is checked from the receiver, not assumed from the sender.

var failures := 0
var passes := 0
var main: Node
var log_path := ""
var asked: Array = []


func _init() -> void:
	log_path = OS.get_environment("FILO_UI_TEST_LOG")
	await _run()


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		failures += 1
		printerr("FAIL: " + msg)
		print("FAIL: " + msg)


func _run() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	main.question_asked.connect(func(text: String, source: String) -> void: asked.append([text, source]))
	for _i in 100:                      # wait for the helper process to connect over the bridge
		if main.helper_connected:
			break
		await create_timer(0.1).timeout
	check(main.helper_connected, "the helper process connected over the real TCP bridge")
	await process_frame
	await process_frame

	test_ui_controls_visible_on_launch()
	test_passthrough_covers_controls()
	await _test_mute_over_ipc()
	await _test_typing_over_ipc()
	_test_status_pill_follows_the_app()
	await test_barge_in_stops_tts()
	await _test_failures_are_spoken_and_shown()
	_test_settings_commands_apply_live()
	_test_control_bar_without_main()

	print("\nui tests: %d passed, %d failed" % [passes, failures])
	main.quit()
	quit(1 if failures > 0 else 0)


func _commands() -> Array:
	var out := []
	if log_path == "" or not FileAccess.file_exists(log_path):
		return out
	for line in FileAccess.get_file_as_string(log_path).split("\n"):
		if line.strip_edges() == "":
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	return out


func _count(cmd: String, key: String = "", value = null) -> int:
	var n := 0
	for c in _commands():
		if c.get("cmd", "") == cmd and (key == "" or c.get(key) == value):
			n += 1
	return n


func _wait_for(cond: Callable, seconds: float = 4.0) -> bool:
	var waited := 0.0
	while waited < seconds:
		if cond.call():
			return true
		await create_timer(0.1).timeout
		waited += 0.1
	return cond.call()


# ------------------------------------------------------------------ launch state

func test_ui_controls_visible_on_launch() -> void:
	var controls: ControlBar = main.controls
	check(controls != null and controls.is_inside_tree(), "the control bar exists in the scene")
	check(main.bubble.mode == Bubble.Mode.HIDDEN and not main.bubble.visible, "at launch the speech bubble is hidden (the old home of the controls)")
	check(controls.is_visible_in_tree() and controls.modulate.a >= 0.5, "...but the control bar is visible and not faded out")
	var names := []
	var window_rect := Rect2(Vector2.ZERO, Vector2(main.get_window().size) / float(main.win_info.scale))
	for b in controls.buttons():
		names.append(str(b.name))
		check(b.is_visible_in_tree(), "%s is visible on launch" % b.name)
		check(b.mouse_filter == Control.MOUSE_FILTER_STOP, "%s takes mouse clicks (mouse_filter STOP, not IGNORE)" % b.name)
		check(b.size.x >= 16.0 and b.size.y >= 16.0, "%s is big enough to hit (%s)" % [b.name, str(b.size)])
		check(window_rect.encloses(b.get_global_rect()), "%s lies inside the overlay window (%s in %s)" % [b.name, str(b.get_global_rect()), str(window_rect)])
		check(b.tooltip_text != "", "%s has a tooltip" % b.name)
	check(names == ["MicButton", "SoundButton", "ModeButton", "TypeButton"], "the bar has mic mute, voice mute, follow-up mode and type: " + str(names))
	check(controls.mode_button.visible, "the follow-up mode button is shown from launch (it used to appear only after the first answer)")
	check(controls.panel.mouse_filter != Control.MOUSE_FILTER_STOP, "the bar's backing panel does not swallow clicks aimed at the game")
	check(not main.controls.mic_button.muted, "the microphone starts unmuted")
	check(main.controls.sound_button.muted == (not main.speaker.enabled), "the voice-mute button mirrors the configured voice state (this run is --mute)")


# ------------------------------------------------------- click-through geometry

func test_passthrough_covers_controls() -> void:
	var controls: ControlBar = main.controls
	var rects: Array = main.interactive_rects()
	check(rects.size() >= 1, "the interactive region is not empty")
	for b in controls.buttons():
		check(ClickRegion.covers(rects, b.get_global_rect()), "the passthrough region covers %s" % b.name)
	# cursor positions -> passthrough decision, at several display scales and window positions
	var window_px := Vector2(1736, 952)
	for sc in [1.0, 2.0, 3.0]:
		for b in controls.buttons():
			var centre_pts: Vector2 = b.get_global_rect().get_center()
			var mouse_px: Vector2 = window_px + centre_pts * sc
			check(not ClickRegion.passthrough_at(mouse_px, window_px, sc, rects), "scale %.0f: a cursor on %s takes the click" % [sc, b.name])
		check(ClickRegion.passthrough_at(window_px + Vector2(5, 5) * sc, window_px, sc, rects), "scale %.0f: the window's top-left corner is click-through" % sc)
		check(ClickRegion.passthrough_at(window_px + Vector2(-50, 20) * sc, window_px, sc, rects), "scale %.0f: outside the window is click-through" % sc)
	# the old bug: the same point in *pixels* must not be mistaken for points (region would be half size at 2x)
	var b0: Control = controls.mic_button
	var wrong_px := window_px + b0.get_global_rect().get_center()      # forgot to multiply by the scale
	check(ClickRegion.passthrough_at(wrong_px, window_px, 2.0, rects), "at 2x a cursor at half the true distance is correctly NOT on the button")

	# the real window follows the decision
	var window := main.get_window()
	main._apply_window_mode()
	# (Window flag getters are not reliable under the headless dummy display server, so the requested mode is checked)
	check(main.window_state.passthrough and main.window_state.unfocusable and not main._fallback_interactive, "idle: the window is click-through and never takes focus: " + str(main.window_state))
	# show / hide
	controls.visible = false
	check(main.interactive_rects().is_empty(), "hidden controls leave no clickable region behind")
	controls.visible = true
	check(main.interactive_rects().size() == rects.size(), "shown controls get their region back")
	# resize
	var old_size := window.size
	window.size = Vector2i(900, 700)
	main._layout_controls()
	_check_bar_inside_window(controls)
	window.size = old_size
	main._layout_controls()
	# DPI change
	var before: float = main.win_info.scale
	main.apply_scale(2.0)
	check(is_equal_approx(window.content_scale_factor, 2.0) and window.size == Vector2i(roundi(main.win_info.size_pts.x * 2.0), roundi(main.win_info.size_pts.y * 2.0)), "a scale change resizes the window to the same size in points")
	main._layout_controls()
	for b in controls.buttons():
		check(ClickRegion.covers(main.interactive_rects(), b.get_global_rect()), "after a scale change the region still covers %s" % b.name)
	main.apply_scale(before)
	main._layout_controls()


func _check_bar_inside_window(controls: ControlBar) -> void:
	var pts := Vector2(main.get_window().size) / float(main.win_info.scale)
	check(controls.position.x >= 0.0 and controls.position.y >= 0.0 and controls.position.x + controls.size.x <= pts.x and controls.position.y + controls.size.y <= pts.y, "after a resize the bar stays inside the window (%s + %s in %s)" % [str(controls.position), str(controls.size), str(pts)])


# ------------------------------------------------------------------- IPC round trips

func _test_mute_over_ipc() -> void:
	var before := _count("set_mute")
	main.controls.mic_button.pressed.emit()
	check(main.mic_muted and main.controls.mic_button.muted, "clicking mute shows the muted state immediately")
	check(await _wait_for(func() -> bool: return _count("set_mute", "muted", true) > 0), "the set_mute{muted:true} command reached the helper process")
	check(await _wait_for(func() -> bool: return main.mic_mute_confirmed), "the helper's mute_state acknowledgement came back and was matched")
	check(_count("set_mute") == before + 1, "exactly one command was sent for one click")
	main.controls.mic_button.pressed.emit()
	check(await _wait_for(func() -> bool: return _count("set_mute", "muted", false) > 0) and not main.mic_muted, "unmuting sends set_mute{muted:false}")
	# the hotkey path: the helper reports a toggle it made itself, the UI mirrors it
	main._on_mute_state(true, "hotkey")
	check(main.mic_muted and main.controls.mic_button.muted, "a mute done with the hotkey shows up on the button")
	main._on_mute_state(false, "hotkey")
	check(not main.mic_muted, "...and unmuting with the hotkey clears it")
	check(str(main.cfg.get_value("hotkey_mute.key", "")) != "" and main.controls.mic_button.tooltip_text == "Mute microphone (⌃⌥ M)", "the mute hotkey is configured and named in the tooltip: " + main.controls.mic_button.tooltip_text)


func _test_typing_over_ipc() -> void:
	asked.clear()
	main.controls.type_button.pressed.emit()     # asleep -> wakes, then opens the box
	check(await _wait_for(func() -> bool: return main.input_panel.is_open(), 6.0), "clicking the type button opens the typed-question box")
	check(await _wait_for(func() -> bool: return _count("focus_save") > 0), "focus_save reached the helper before Filo took the keyboard")
	await create_timer(0.3).timeout
	check(main.input_panel.line.has_focus(), "the text field has keyboard focus")
	check(not main.window_state.passthrough and not main.window_state.unfocusable, "while typing the window accepts clicks and keyboard focus: " + str(main.window_state))
	check(main.controls.type_button.active, "the type button shows it is active")
	main.input_panel.submitted.emit("who is lady butterfly")   # what pressing Enter does
	check(asked.size() == 1 and asked[0] == ["who is lady butterfly", "typed"], "a typed question goes through _ask(): " + str(asked))
	check(await _wait_for(func() -> bool: return _count("focus_restore") > 0), "closing the box asked the helper to give focus back to the game")
	main._apply_window_mode()
	check(main.window_state.passthrough and main.window_state.unfocusable, "after typing the window is click-through and unfocusable again: " + str(main.window_state))
	check(not main.controls.type_button.active, "the type button is inactive again")
	# the same question by voice takes the same path
	await _wait_for(func() -> bool: return main.app_state != main.AppState.THINKING, 10.0)
	main.app_state = main.AppState.LISTENING
	main._on_final("who is lady butterfly")
	# (voice questions pass through TermCorrector first, which re-cases the boss name: compare case-insensitively)
	check(asked.size() == 2 and str(asked[1][0]).to_lower() == "who is lady butterfly" and asked[1][1] == "voice", "the same question said aloud takes the same _ask() path: " + str(asked))


func _test_control_bar_without_main() -> void:
	var bar := ControlBar.new()
	root.add_child(bar)
	check(bar.is_visible_in_tree() and bar.buttons().size() == 4 and bar.interactive_rects().size() == 1, "a control bar on its own is visible with four buttons and one clickable region")
	bar.mic_button.set_muted(true)
	check(bar.mic_button.muted and bar.mic_button.tooltip_text.begins_with("Unmute"), "the mic button shows and explains its muted state")
	var clicks := [0]
	bar.type_button.pressed.connect(func() -> void: clicks[0] += 1)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	bar.type_button._gui_input(ev)
	check(clicks[0] == 1, "a left-button release on a control emits `pressed`")
	bar.queue_free()


# -------------------------------------------------------------------- status + barge-in

func _test_status_pill_follows_the_app() -> void:
	main.mic_muted = false
	main.controls.mic_button.set_muted(false)
	main._error_until = 0.0
	main._heard_until = 0.0
	var seen := {}
	for st in ["LISTENING", "THINKING", "ANSWERING", "TYPING", "IDLE"]:
		main.app_state = main.AppState[st]
		main.controls.status.set_kind(main._status_kind())
		seen[st] = main.controls.status.label()
	check(seen == {"LISTENING": "Listening", "THINKING": "Thinking", "ANSWERING": "Speaking", "TYPING": "Typing", "IDLE": "Ready"}, "the control bar's status follows the app state: " + str(seen))
	main.mic_muted = true
	main.controls.status.set_kind(main._status_kind())
	check(main.controls.status.label() == "Mic muted", "muting the microphone shows 'Mic muted'")
	main.mic_muted = false
	main._heard_until = Time.get_ticks_msec() / 1000.0 + 5.0
	main.app_state = main.AppState.THINKING
	main.controls.status.set_kind(main._status_kind())
	check(main.controls.status.label() == "Heard you", "right after a transcript arrives the status says it was heard")
	main._heard_until = 0.0
	main._show_error("test error")
	main.speaker.stop()                # the failure message is spoken (see _test_failures_are_spoken_and_shown)
	main.controls.status.set_kind(main._status_kind())
	check(main.controls.status.label() == "Problem", "an error shows 'Problem'")
	main._error_until = 0.0
	main.app_state = main.AppState.THINKING
	main.pipeline.current_route = "tool_loop"
	main._on_ack_timeout()
	check(main.bubble.thinking_label == "Looking that up", "a slow tool-loop answer changes the wait message to 'Looking that up'")
	main.pipeline.current_route = ""
	main.bubble.thinking_label = "Thinking"
	main._on_ack_timeout()
	check(main.bubble.thinking_label == "Thinking", "a fast or non-tool route gets no acknowledgement")


## Pressing the talk hotkey or saying the wake phrase while Filo talks (or is about to) stops it at once and
## resets the pipeline: no stale 'finished', no tail spoken later, no late answer overwriting the new turn.
func test_barge_in_stops_tts() -> void:
	var sp: Speaker = main.speaker
	sp.stop()                          # start from silence: earlier tests may have left something speaking
	var cancelled := [0]
	var finished := [0]
	sp.cancelled.connect(func(_i: int) -> void: cancelled[0] += 1)
	sp.finished.connect(func(_i: int) -> void: finished[0] += 1)
	var long_text := "This is a long answer that takes quite a while to say out loud, so there is time to interrupt it."
	# 1) the hotkey while an answer is being spoken
	main._set_state(main.AppState.ANSWERING)
	main._speak(long_text, "answer")
	check(sp.is_speaking(), "barge-in setup: Filo is speaking")
	var token: int = main._answer_token
	main._on_hotkey_down()
	check(not sp.is_speaking(), "the hotkey stops the speech in the same frame")
	check(cancelled[0] == 1 and main.app_state == main.AppState.LISTENING, "the speech is cancelled once and Filo is listening")
	check(main._answer_token == token + 1 and main.speech_watchdog.is_stopped() and main._speech_kind == "", "the pipeline is reset: answer superseded, watchdog stopped, speech bookkeeping cleared")
	await create_timer(0.7).timeout
	check(finished[0] == 0, "no stale 'finished' arrives after the interruption (it would trigger a reprompt)")
	# 2) the wake phrase while a streamed head is speaking and its tail is queued
	main._set_state(main.AppState.ANSWERING)
	main._speak("Dodge its charges and stay near the platforms.", "answer", true)
	sp.append("Then kill the servants when the second phase starts.")
	check(sp.is_speaking() and sp._tail_text != "", "barge-in setup 2: a head is speaking with a tail queued")
	main._on_wake_word("hey filo")
	check(not sp.is_speaking() and sp._tail_text == "" and not sp._more_expected, "saying the wake phrase stops the head and drops the queued tail")
	await create_timer(0.7).timeout
	check(finished[0] == 0 and cancelled[0] == 2, "the tail is never spoken afterwards (cancelled %d, finished %d)" % [cancelled[0], finished[0]])
	# 3) while an answer is still on its way (thinking): it must not surface later
	main._set_state(main.AppState.THINKING)
	var old_token: int = main._answer_token
	main._on_hotkey_down()
	check(main.app_state == main.AppState.LISTENING and main._answer_token == old_token + 1 and main.ack_timer.is_stopped(), "interrupting a pending answer supersedes it and stops the acknowledgement timer")
	var streamed := {"head": ""}
	main._on_streamed_head(old_token, "old question", "A late first sentence from the old answer arrives now.", streamed)
	check(streamed.head == "" and main.app_state == main.AppState.LISTENING and not sp.is_speaking(), "a first sentence from the superseded answer is ignored")
	# 4) the type button interrupts too
	main._set_state(main.AppState.ANSWERING)
	main._speak(long_text, "answer")
	main._interrupt_speech()
	check(not sp.is_speaking(), "_interrupt_speech() is safe to call at any time and stops everything")
	main._interrupt_speech()
	check(cancelled[0] == 3, "...and calling it again with nothing to stop does nothing")


func _test_failures_are_spoken_and_shown() -> void:
	main._failure_spoken.clear()
	main.speaker.last_text = ""
	main._show_error("I can't reach NVIDIA NIM — is the internet connected?")
	check(main.bubble.mode == Bubble.Mode.ERROR and main.bubble.body.text.contains("internet"), "a failure is shown in the bubble: '%s'" % main.bubble.body.text)
	check(main.speaker.last_text == "I can't reach the internet right now.", "...and spoken in one short sentence: '%s'" % main.speaker.last_text)
	main.speaker.last_text = ""
	await create_timer(0.3).timeout
	main._show_error("I can't reach Claude — is the internet connected?")
	check(main.speaker.last_text == "" and main.bubble.mode == Bubble.Mode.ERROR, "the same complaint is not spoken twice in a row (it is still shown)")
	main._on_helper_error("no_input_device", "No microphone input was found (noInput).")
	check(main.speaker.last_text.begins_with("I can't find a microphone"), "a helper error (no microphone) is spoken too: '%s'" % main.speaker.last_text)
	main._on_helper_error("mic_denied", "Microphone access is off.")
	check(main.speaker.last_text.contains("permission"), "microphone permission denied is spoken: '%s'" % main.speaker.last_text)
	main.speaker.stop()


func _test_settings_commands_apply_live() -> void:
	main._on_typed_submitted("/opacity 55")
	check(is_equal_approx(main.modulate.a, 0.55) and main.bubble.body.text.begins_with("Opacity 55"), "typing /opacity 55 dims the overlay at once and confirms in the bubble")
	main._on_typed_submitted("/text 130")
	main._on_typed_submitted("/contrast on")
	check(main.bubble.high_contrast and is_equal_approx(main.bubble.text_scale, 1.3), "/text and /contrast take effect at once")
	main._on_typed_submitted("/spoilers full")
	check(main.pipeline.default_level() == "full", "/spoilers changes what the next answer gives away")
	main._on_typed_submitted("/opacity 100")
	main._on_typed_submitted("/text 100")
	main._on_typed_submitted("/contrast off")
	main._on_typed_submitted("/spoilers hint")
	check(is_equal_approx(main.modulate.a, 1.0) and not main.bubble.high_contrast, "and back")
