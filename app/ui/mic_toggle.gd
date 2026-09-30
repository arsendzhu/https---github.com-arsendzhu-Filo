class_name MicToggle
extends IconButton
## Microphone mute: a mic glyph, struck through and red while the microphone is muted. Purely a
## view - Main owns what muted means (the helper stops listening, the wake word goes deaf).

var muted := false
var hotkey_label := ""


func _ready() -> void:
	super._ready()
	_update_tooltip()


func set_muted(m: bool) -> void:
	if muted == m:
		return
	muted = m
	_update_tooltip()
	queue_redraw()


func set_hotkey_label(label: String) -> void:
	hotkey_label = label
	_update_tooltip()


func _update_tooltip() -> void:
	tooltip_text = ("Unmute microphone" if muted else "Mute microphone") + (" (%s)" % hotkey_label if hotkey_label != "" else "")


func _draw() -> void:
	var c := ALERT if muted else glyph_color()
	draw_rect(Rect2(9.0, 3.0, 6.0, 10.0), c)
	draw_arc(Vector2(12.0, 12.0), 5.5, 0.0, PI, 10, c, 1.5, true)
	draw_line(Vector2(12.0, 17.5), Vector2(12.0, 20.0), c, 1.5, true)
	draw_line(Vector2(8.0, 20.0), Vector2(16.0, 20.0), c, 1.5, true)
	if muted:
		draw_line(Vector2(4.0, 4.0), Vector2(20.0, 20.0), c, 2.0, true)
