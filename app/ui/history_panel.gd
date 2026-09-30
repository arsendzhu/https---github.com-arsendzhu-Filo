class_name HistoryPanel
extends Control
## The last few questions and answers as plain text (never sources, URLs or audio), in a small scrollable
## panel above the control bar. Kept in memory only for this session.

const MAX_ENTRIES := 10
const INK := Color("1d1826")
const CREAM := Color("f1dcbc")

var panel: PanelContainer
var list: VBoxContainer
var scroll: ScrollContainer
var entries: Array = []          # [{q, a, game}] oldest first


func _ready() -> void:
	name = "HistoryPanel"
	mouse_filter = MOUSE_FILTER_IGNORE
	panel = PanelContainer.new()
	panel.mouse_filter = MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.95)
	style.border_color = CREAM
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	box.mouse_filter = MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var title := Label.new()
	title.text = "Recent questions"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color("bfb3a6"))
	box.add_child(title)
	scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360.0, 0.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	list = VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	list.mouse_filter = MOUSE_FILTER_IGNORE
	list.custom_minimum_size = Vector2(350.0, 0.0)
	scroll.add_child(list)
	visible = false
	_rebuild()


func is_open() -> bool:
	return visible


func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()


## Adds a finished exchange (text only) and keeps the newest MAX_ENTRIES.
func add_entry(question: String, answer: String, game: String) -> void:
	entries.append({"q": question.strip_edges(), "a": answer.strip_edges(), "game": game})
	while entries.size() > MAX_ENTRIES:
		entries.pop_front()
	if visible:
		_rebuild()


func rect_global() -> Rect2:
	return panel.get_global_rect() if visible else Rect2()


func _rebuild() -> void:
	if list == null:
		return
	for c in list.get_children():
		c.queue_free()
	if entries.is_empty():
		list.add_child(_label("Nothing yet - ask me something.", 13, Color("8f8577")))
		return
	for i in range(entries.size() - 1, -1, -1):        # newest first
		var e: Dictionary = entries[i]
		list.add_child(_label("You: " + str(e.q), 12, Color("bfb3a6")))
		list.add_child(_label(str(e.a), 13, Color("f6efe4")))
	scroll.custom_minimum_size.y = minf(260.0, 40.0 + 44.0 * entries.size())


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(340.0, 0.0)
	l.mouse_filter = MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
