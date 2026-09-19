class_name InputPanel
extends Control
## Typed-question fallback: tap the hotkey and type instead of talking.
## Enter submits, Escape closes. The overlay window is made focusable by Main
## only while this panel is open.

signal submitted(text: String)
signal closed

const CREAM := Color("f1dcbc")
const INK := Color("1d1826")

var panel: PanelContainer
var line: LineEdit
var _tween: Tween


func _ready() -> void:
	panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.96)
	style.border_color = CREAM
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	line = LineEdit.new()
	line.placeholder_text = "Ask Filo…   Enter to send · Esc to close"
	line.custom_minimum_size = Vector2(340.0, 34.0)
	line.add_theme_font_size_override("font_size", 15)
	line.add_theme_color_override("font_color", Color("f6efe4"))
	line.add_theme_color_override("font_placeholder_color", Color("8f8577"))
	line.add_theme_color_override("caret_color", CREAM)
	var line_style := StyleBoxFlat.new()
	line_style.bg_color = Color("2a2434")
	line_style.set_corner_radius_all(4)
	line_style.content_margin_left = 8.0
	line_style.content_margin_right = 8.0
	line_style.content_margin_top = 4.0
	line_style.content_margin_bottom = 4.0
	line.add_theme_stylebox_override("normal", line_style)
	line.add_theme_stylebox_override("focus", line_style)
	line.text_submitted.connect(_on_submitted)
	line.gui_input.connect(_on_gui_input)
	panel.add_child(line)
	visible = false
	modulate.a = 0.0


func _process(_delta: float) -> void:
	size = panel.size


func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		line.grab_focus()
		return
	visible = true
	line.text = ""
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.15)
	line.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	modulate.a = 0.0
	line.release_focus()
	closed.emit()


func _on_submitted(text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		return
	submitted.emit(t)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		accept_event()
		close()
