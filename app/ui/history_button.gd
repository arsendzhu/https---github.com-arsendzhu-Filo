class_name HistoryButton
extends IconButton
## Opens/closes the panel with the last questions and answers: a small list glyph. Purely a view.

var active := false


func _ready() -> void:
	super._ready()
	tooltip_text = "Recent questions"


func set_active(a: bool) -> void:
	if active == a:
		return
	active = a
	tooltip_text = "Hide the recent questions" if a else "Recent questions"
	queue_redraw()


func _draw() -> void:
	var c := Color("8be0d8") if active else glyph_color()
	for i in 3:
		var y := 6.0 + i * 5.5
		draw_circle(Vector2(6.0, y), 1.4, c)
		draw_line(Vector2(10.0, y), Vector2(20.0, y), c, 1.6, true)
