class_name ControlBar
extends Control
## The always-visible strip of small controls next to the mascot:
##   mic mute · voice mute · follow-up mode (voice/typing) · type a question
## It lives outside the speech bubble on purpose: the bubble is hidden until Filo has something to
## say, which is why the controls used to be missing on first launch. The bar is visible from the
## first frame, on a dark pill so the glyphs read on any game background.

const INK := Color("1d1826")
const CREAM := Color("f1dcbc")
const MARGIN := 6.0

var panel: PanelContainer
var mic_button: MicToggle
var sound_button: SoundToggle
var mode_button: ModeToggle
var type_button: TypeButton
var status: StatusPill
var rest_alpha := 0.9


func _ready() -> void:
	name = "ControlBar"
	mouse_filter = MOUSE_FILTER_IGNORE   # the strip itself never eats clicks; its buttons (STOP) do
	panel = PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.82)
	style.border_color = Color(CREAM, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = MARGIN + 2.0
	style.content_margin_right = MARGIN + 2.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.mouse_filter = MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	status = StatusPill.new()
	row.add_child(status)
	mic_button = MicToggle.new()
	mic_button.name = "MicButton"
	sound_button = SoundToggle.new()
	sound_button.name = "SoundButton"
	mode_button = ModeToggle.new()
	mode_button.name = "ModeButton"
	type_button = TypeButton.new()
	type_button.name = "TypeButton"
	for b in [mic_button, sound_button, mode_button, type_button]:
		row.add_child(b)
	mode_button.visible = true   # the bar shows every control from the first frame
	modulate.a = rest_alpha
	size = panel.get_combined_minimum_size()


func buttons() -> Array:
	return [mic_button, sound_button, mode_button, type_button]


## The rects (window-local points) that take clicks. Empty while the bar is hidden.
func interactive_rects() -> Array:
	if not is_visible_in_tree():
		return []
	return [panel.get_global_rect()]


func _process(_delta: float) -> void:
	size = panel.size
