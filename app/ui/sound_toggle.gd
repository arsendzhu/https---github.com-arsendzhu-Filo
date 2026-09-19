class_name SoundToggle
extends Control
## A very subtle mute/unmute button in the bubble's bottom-left corner: a
## small speaker glyph, sound-wave ticks when voice is on, a single slash
## through it when muted. Purely a view — Main owns what "muted" means.

signal pressed

const GLYPH := Color("bfb3a6")

var muted := false


func _ready() -> void:
	custom_minimum_size = Vector2(20.0, 20.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "Mute voice"


func set_muted(m: bool) -> void:
	if muted == m:
		return
	muted = m
	tooltip_text = "Unmute voice" if muted else "Mute voice"
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		accept_event()
		pressed.emit()


func _draw() -> void:
	var c := GLYPH
	draw_rect(Rect2(2.0, 7.0, 3.0, 6.0), c)
	var cone := PackedVector2Array([Vector2(5.0, 7.0), Vector2(10.0, 3.5), Vector2(10.0, 16.5), Vector2(5.0, 13.0)])
	draw_colored_polygon(cone, c)
	if muted:
		draw_line(Vector2(3.0, 3.0), Vector2(17.0, 17.0), c, 1.6, true)
	else:
		draw_arc(Vector2(10.0, 10.0), 6.0, -0.6, 0.6, 8, c, 1.4, true)
		draw_arc(Vector2(10.0, 10.0), 9.5, -0.5, 0.5, 8, c, 1.4, true)
