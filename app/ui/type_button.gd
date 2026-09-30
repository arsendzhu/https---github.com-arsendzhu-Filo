class_name TypeButton
extends IconButton
## Opens (or closes) the typed-question box: a speech bubble with a text cursor. Purely a view.

var active := false


func _ready() -> void:
	super._ready()
	tooltip_text = "Type a question"


func set_active(a: bool) -> void:
	if active == a:
		return
	active = a
	tooltip_text = "Close the text box" if a else "Type a question"
	queue_redraw()


func _draw() -> void:
	var c := Color("8be0d8") if active else glyph_color()
	draw_rect(Rect2(3.0, 4.0, 18.0, 12.0), c, false, 1.6, true)
	draw_colored_polygon(PackedVector2Array([Vector2(7.0, 16.0), Vector2(7.0, 21.0), Vector2(12.0, 16.0)]), c)
	draw_line(Vector2(9.0, 7.0), Vector2(9.0, 13.0), c, 1.5, true)
	draw_line(Vector2(12.0, 10.0), Vector2(17.0, 10.0), c, 1.5, true)
