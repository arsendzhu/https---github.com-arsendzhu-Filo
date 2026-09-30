class_name IconButton
extends Control
## Base for the small glyph buttons of the control bar: a fixed-size, always-STOP-filter control that
## emits `pressed` on left-button release and highlights on hover. Subclasses draw the glyph.

signal pressed

const GLYPH := Color("bfb3a6")
const GLYPH_HOT := Color("f6efe4")
const ALERT := Color("f39a9a")

var hover := false


func _ready() -> void:
	custom_minimum_size = Vector2(24.0, 24.0)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void:
		hover = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		hover = false
		queue_redraw())


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		accept_event()
		pressed.emit()


func glyph_color() -> Color:
	return GLYPH_HOT if hover else GLYPH
