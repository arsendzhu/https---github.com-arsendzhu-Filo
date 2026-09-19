class_name ModeToggle
extends Control
## A very subtle voice/text toggle for follow-up questions, shown once the
## conversation has had its first answer: a mic glyph while in voice mode, a
## small keyboard glyph while in text mode. Purely a view — Main decides what
## each mode actually does.

signal pressed

const GLYPH := Color("bfb3a6")

var mode := "voice"   # voice | text


func _ready() -> void:
	custom_minimum_size = Vector2(20.0, 20.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	visible = false
	tooltip_text = "Switch to typing"


func set_mode(m: String) -> void:
	if mode == m:
		return
	mode = m
	tooltip_text = "Switch to typing" if mode == "voice" else "Switch to talking"
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		accept_event()
		pressed.emit()


func _draw() -> void:
	var c := GLYPH
	if mode == "voice":
		draw_rect(Rect2(7.0, 2.0, 6.0, 9.0), c)
		draw_arc(Vector2(10.0, 11.0), 5.0, 0.0, PI, 10, c, 1.4, true)
		draw_line(Vector2(10.0, 16.0), Vector2(10.0, 18.5), c, 1.4, true)
		draw_line(Vector2(6.5, 18.5), Vector2(13.5, 18.5), c, 1.4, true)
	else:
		draw_rect(Rect2(2.0, 5.0, 16.0, 10.0), c, false, 1.4, true)
		for row in 2:
			for col in 4:
				draw_rect(Rect2(4.5 + col * 3.3, 7.5 + row * 3.3, 1.6, 1.6), c)
