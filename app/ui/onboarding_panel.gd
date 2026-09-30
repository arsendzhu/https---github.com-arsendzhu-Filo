class_name OnboardingPanel
extends Control
## First-run setup, four short steps in one panel: pick the microphone (with a live level meter), check the hotkey,
## hear the voice, choose the game. Re-run any time with /setup. Everything it changes goes through Main (which
## talks to the helper and saves settings); this class is only the view.

signal mic_selected(uid: String)
signal mic_test_requested(on: bool)
signal voice_test_requested
signal game_selected(id: String)
signal finished

const INK := Color("1d1826")
const CREAM := Color("f1dcbc")
const DIM := Color("bfb3a6")
const OK := Color("7bd88f")

var devices: Array = []           # [{uid, name, default}]
var mic_index := 0
var games: Array = []             # [{id, name}]
var game_index := 0
var hotkey_seen := false
var hotkey_label := "the hotkey"
var panel: PanelContainer
var mic_name: Label
var meter: ProgressBar
var hotkey_status: Label
var game_name: Label
var _level := 0.0


func _ready() -> void:
	name = "OnboardingPanel"
	mouse_filter = MOUSE_FILTER_IGNORE
	panel = PanelContainer.new()
	panel.mouse_filter = MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.97)
	style.border_color = CREAM
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.custom_minimum_size = Vector2(390.0, 0.0)
	panel.add_child(box)
	box.add_child(_label("Let's get set up", 16, Color("f6efe4")))
	# 1 microphone
	box.add_child(_label("1  Microphone", 12, DIM))
	var mic_row := HBoxContainer.new()
	mic_row.add_child(_button("◀", func() -> void: _step_mic(-1), "MicPrev"))
	mic_name = _label("looking for microphones…", 13, Color("f6efe4"))
	mic_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mic_name.clip_text = true
	mic_row.add_child(mic_name)
	mic_row.add_child(_button("▶", func() -> void: _step_mic(1), "MicNext"))
	box.add_child(mic_row)
	meter = ProgressBar.new()
	meter.name = "Meter"
	meter.min_value = 0.0
	meter.max_value = 1.0
	meter.show_percentage = false
	meter.custom_minimum_size = Vector2(0.0, 8.0)
	box.add_child(meter)
	box.add_child(_label("Say something: the bar should move.", 11, DIM))
	# 2 hotkey
	box.add_child(_label("2  Hotkey", 12, DIM))
	hotkey_status = _label("Press the hotkey now…", 13, Color("f6efe4"))
	box.add_child(hotkey_status)
	# 3 voice
	box.add_child(_label("3  Voice", 12, DIM))
	box.add_child(_button("Play a test sentence", func() -> void: voice_test_requested.emit(), "VoiceTest"))
	# 4 game
	box.add_child(_label("4  Game", 12, DIM))
	var game_row := HBoxContainer.new()
	game_row.add_child(_button("◀", func() -> void: _step_game(-1), "GamePrev"))
	game_name = _label("", 13, Color("f6efe4"))
	game_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_row.add_child(game_name)
	game_row.add_child(_button("▶", func() -> void: _step_game(1), "GameNext"))
	box.add_child(game_row)
	box.add_child(_button("Done", func() -> void: finished.emit(), "Done"))
	visible = false


func _process(_delta: float) -> void:
	if visible:
		size = panel.size
		_level = maxf(0.0, _level - 0.03)             # the meter falls back between events
		meter.value = _level


func is_open() -> bool:
	return visible


func open(hotkey: String) -> void:
	hotkey_label = hotkey
	hotkey_seen = false
	hotkey_status.text = "Press %s now…" % hotkey
	hotkey_status.add_theme_color_override("font_color", Color("f6efe4"))
	visible = true
	mic_test_requested.emit(true)


func close() -> void:
	if visible:
		visible = false
		mic_test_requested.emit(false)


func rect_global() -> Rect2:
	return panel.get_global_rect() if visible else Rect2()


func set_devices(list: Array, selected_uid: String) -> void:
	devices = list
	mic_index = 0
	for i in devices.size():
		if str(devices[i].get("uid", "")) == selected_uid and selected_uid != "":
			mic_index = i
			break
		if selected_uid == "" and bool(devices[i].get("default", false)):
			mic_index = i
	_show_mic()


func set_level(v: float) -> void:
	_level = maxf(_level, clampf(v, 0.0, 1.0))


func on_hotkey() -> void:
	hotkey_seen = true
	hotkey_status.text = "✓ Got it - %s works." % hotkey_label
	hotkey_status.add_theme_color_override("font_color", OK)


func set_games(list: Array, current_id: String) -> void:
	games = list
	game_index = 0
	for i in games.size():
		if str(games[i].id) == current_id:
			game_index = i
	_show_game()


func selected_mic_uid() -> String:
	return str(devices[mic_index].get("uid", "")) if not devices.is_empty() else ""


func _step_mic(d: int) -> void:
	if devices.is_empty():
		return
	mic_index = posmod(mic_index + d, devices.size())
	_show_mic()
	mic_selected.emit(selected_mic_uid())


func _step_game(d: int) -> void:
	if games.is_empty():
		return
	game_index = posmod(game_index + d, games.size())
	_show_game()
	game_selected.emit(str(games[game_index].id))


func _show_mic() -> void:
	if devices.is_empty():
		mic_name.text = "no microphone found"
		return
	var d: Dictionary = devices[mic_index]
	mic_name.text = "%s%s" % [str(d.get("name", "?")), "  (default)" if d.get("default", false) else ""]


func _show_game() -> void:
	game_name.text = str(games[game_index].name) if not games.is_empty() else "no games found"


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	return l


func _button(text: String, cb: Callable, node_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE                # clicking must never pull keyboard focus away from the game
	b.pressed.connect(cb)
	return b
