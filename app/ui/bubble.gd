class_name Bubble
extends Control
## The mascot's speech bubble: a crisp, chunky-bordered panel (kept at full
## resolution so answers stay readable) with a small tail pointing at the cube.
## Modes: listening (live transcript), thinking (animated dots), answer (text
## revealed word by word as it is spoken, plus sources), error, info.

enum Mode { HIDDEN, LISTENING, THINKING, ANSWER, ERROR, INFO, FOLLOWUP }

const CREAM := Color("f1dcbc")
const INK := Color("1d1826")
const DIM := Color("bfb3a6")
const ACCENT := Color("8be0d8")
const ERROR_COLOR := Color("f39a9a")
const BODY_COLOR := Color("f6efe4")

var mode: int = Mode.HIDDEN
var panel: PanelContainer
var header: Label
var body: Label
var footer: Label
var max_width := 340.0
var tail_y := 40.0
var tail_anchor_x := 0.0     # x of the tail tip, set by Main every frame
var bottom_anchor_y := 0.0   # y of the bubble's bottom edge
var tail_target_y := 0.0     # y the tail points at (the cube's centre)
var _dots_time := 0.0
var _tween: Tween
var _style: StyleBoxFlat


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	panel = PanelContainer.new()
	panel.mouse_filter = MOUSE_FILTER_IGNORE
	_style = StyleBoxFlat.new()
	_style.bg_color = Color(INK, 0.94)
	_style.border_color = CREAM
	_style.set_border_width_all(2)
	_style.set_corner_radius_all(10)
	_style.content_margin_left = 16.0
	_style.content_margin_right = 16.0
	_style.content_margin_top = 11.0
	_style.content_margin_bottom = 11.0
	panel.add_theme_stylebox_override("panel", _style)
	add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(vbox)
	header = _make_label(12, DIM)
	body = _make_label(15, BODY_COLOR)
	footer = _make_label(12, ACCENT)
	vbox.add_child(header)
	vbox.add_child(body)
	vbox.add_child(footer)
	visible = false
	modulate.a = 0.0


func _make_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = MOUSE_FILTER_IGNORE
	l.visible = false
	return l


func _process(delta: float) -> void:
	size = panel.size
	if tail_anchor_x > 0.0:
		position = Vector2(tail_anchor_x - size.x, bottom_anchor_y - size.y)
		tail_y = tail_target_y - position.y
	if mode == Mode.THINKING:
		_dots_time += delta
		footer.text = "Thinking" + ".".repeat(int(_dots_time * 3.0) % 4)
	elif mode == Mode.LISTENING:
		# a persistent, pulsing microphone indicator while the mic is open
		_dots_time += delta
		header.text = ("●" if int(_dots_time * 2.0) % 2 == 0 else "○") + "  Listening" + ("…" if body.text == "" else "")
	queue_redraw()


func _draw() -> void:
	if not visible or panel.size.x <= 0.0:
		return
	var x := panel.size.x - 2.0
	var y := clampf(tail_y, 16.0, panel.size.y - 16.0)
	var outer := PackedVector2Array([Vector2(x, y - 9.0), Vector2(x + 12.0, y + 1.0), Vector2(x, y + 10.0)])
	var inner := PackedVector2Array([Vector2(x - 1.0, y - 5.0), Vector2(x + 8.0, y + 1.0), Vector2(x - 1.0, y + 6.5)])
	draw_colored_polygon(outer, _style.border_color)
	draw_colored_polygon(inner, _style.bg_color)


# ------------------------------------------------------------------ modes

func show_listening(partial: String, followup: bool = false) -> void:
	_set_mode(Mode.LISTENING)
	header.text = "●  Listening" + ("…" if partial == "" else "")
	_set_body(partial if partial != "" else " ")
	if followup and partial == "":
		footer.text = "say “bye filo” when you're done"
		footer.visible = true
	else:
		footer.visible = false


## After an answer: the spoken "anything else?" plus how to end the chat.
func show_followup(prompt: String, bye_phrase: String, hotkey: String) -> void:
	_set_mode(Mode.FOLLOWUP)
	header.text = "Filo"
	_set_body(prompt)
	footer.text = "say “%s” or tap %s to dismiss" % [bye_phrase, hotkey]
	footer.visible = true


func show_thinking(question: String) -> void:
	_set_mode(Mode.THINKING)
	header.text = "You asked"
	_set_body(question)
	footer.text = "Thinking"
	footer.visible = true


func show_answer(question: String, text: String, sources: Array, used_web: bool) -> void:
	_set_mode(Mode.ANSWER)
	header.text = "You asked: " + _truncate(question, 90)
	_set_body(text)
	body.visible_characters = 0
	var src := format_sources(sources, used_web)
	footer.text = src
	footer.visible = src != ""


## The full answer arrived after only its first sentence was shown (streamed speech): swap the text in place,
## keeping how much of it has been revealed so far.
func update_answer(text: String, sources: Array, used_web: bool) -> void:
	if mode != Mode.ANSWER:
		return
	var keep := body.visible_characters
	_set_body(text)
	body.visible_characters = keep
	var src := format_sources(sources, used_web)
	footer.text = src
	footer.visible = src != ""


func show_error(message: String) -> void:
	_set_mode(Mode.ERROR)
	header.text = "Hmm"
	_set_body(message)
	footer.visible = false


func show_info(text: String) -> void:
	_set_mode(Mode.INFO)
	header.text = "Filo"
	_set_body(text)
	footer.visible = false


func hide_bubble() -> void:
	if mode == Mode.HIDDEN:
		return
	mode = Mode.HIDDEN
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_SINE)
	_tween.tween_callback(func() -> void: visible = false)


## Reveal the answer text up to the end of the word that starts at char_index.
func reveal_to(char_index: int) -> void:
	if mode != Mode.ANSWER:
		return
	var text := body.text
	var end := text.find(" ", char_index)
	if end < 0:
		end = text.length()
	body.visible_characters = clampi(end, 0, text.length())


func reveal_all() -> void:
	body.visible_characters = -1


static func format_sources(sources: Array, used_web: bool) -> String:
	var parts := PackedStringArray()
	for s in sources:
		var title := str(s.get("title", "")).strip_edges()
		var url := str(s.get("url", ""))
		if str(s.get("kind", "")) == "web":
			var domain := url.trim_prefix("https://").trim_prefix("http://").split("/")[0]
			parts.append("web: " + (title if title != "" else domain) + ("  (" + domain + ")" if domain != "" and title != "" else ""))
		else:
			parts.append("notes: " + (title if title != "" else "untitled"))
	if parts.is_empty():
		return "◆ searched the web" if used_web else ""
	return "◆ " + "   ".join(parts)


# ---------------------------------------------------------------- internals

func _set_mode(m: int) -> void:
	var was_hidden := (mode == Mode.HIDDEN) or not visible
	mode = m
	_dots_time = 0.0
	header.visible = true
	body.visible = true
	header.add_theme_color_override("font_color", ERROR_COLOR if m == Mode.ERROR else DIM)
	_style.border_color = ERROR_COLOR if m == Mode.ERROR else CREAM
	body.visible_characters = -1
	if was_hidden:
		_appear()
	else:
		_kill_tween()
		modulate.a = 1.0
		scale = Vector2.ONE
		visible = true


func _set_body(text: String) -> void:
	body.text = text
	var font := body.get_theme_font("font")
	var font_size := body.get_theme_font_size("font_size")
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + 6.0
	var target := clampf(w, 120.0, max_width)
	body.custom_minimum_size.x = target
	header.custom_minimum_size.x = target
	footer.custom_minimum_size.x = target


func _appear() -> void:
	_kill_tween()
	visible = true
	modulate.a = 0.0
	pivot_offset = Vector2(panel.size.x, panel.size.y * 0.5)
	scale = Vector2(0.9, 0.9)
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, 0.16).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(self, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()


static func _truncate(s: String, n: int) -> String:
	return s if s.length() <= n else s.left(n - 1) + "…"
