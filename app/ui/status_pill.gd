class_name StatusPill
extends Control
## A small always-visible state indicator: a coloured dot and one word (Ready, Listening, Heard you,
## Thinking, Speaking, Typing, Mic muted, Problem), so it is always clear whether Filo heard you and
## what it is doing. Purely a view; Main decides the kind.

const STATES := {
	"ready": {"label": "Ready", "color": Color("8f8577")},
	"listening": {"label": "Listening", "color": Color("7bd88f")},
	"heard": {"label": "Heard you", "color": Color("8be0d8")},
	"thinking": {"label": "Thinking", "color": Color("f0c674")},
	"speaking": {"label": "Speaking", "color": Color("8be0d8")},
	"typing": {"label": "Typing", "color": Color("b7a6f0")},
	"muted": {"label": "Mic muted", "color": Color("f39a9a")},
	"error": {"label": "Problem", "color": Color("f39a9a")},
}
const TEXT := Color("d9cfc2")

var kind := "ready"
var _t := 0.0


func _ready() -> void:
	name = "StatusPill"
	mouse_filter = Control.MOUSE_FILTER_IGNORE      # a label, not a control: never eats clicks
	custom_minimum_size = Vector2(92.0, 24.0)
	size = custom_minimum_size
	tooltip_text = ""


## The kind for the app's situation (pure, so it can be tested without a scene).
static func kind_for(state_name: String, mic_muted: bool, error_recent: bool, heard_recent: bool) -> String:
	if mic_muted:
		return "muted"
	if error_recent:
		return "error"
	if heard_recent and state_name in ["THINKING", "LISTENING"]:
		return "heard"
	match state_name:
		"LISTENING", "WAKING":
			return "listening" if state_name == "LISTENING" else "ready"
		"THINKING":
			return "thinking"
		"ANSWERING":
			return "speaking"
		"TYPING":
			return "typing"
		_:
			return "ready"


func set_kind(k: String) -> void:
	if not STATES.has(k) or k == kind:
		return
	kind = k
	queue_redraw()


func label() -> String:
	return str(STATES[kind].label)


func _process(delta: float) -> void:
	_t += delta
	if kind in ["listening", "thinking", "heard"]:
		queue_redraw()          # the dot pulses while something is going on


func _draw() -> void:
	var c: Color = STATES[kind].color
	var pulse := 1.0
	if kind in ["listening", "thinking"]:
		pulse = 0.65 + 0.35 * sin(_t * 5.0)
	draw_circle(Vector2(9.0, size.y * 0.5), 4.5, Color(c, pulse))
	if kind == "muted" or kind == "error":
		draw_line(Vector2(5.0, size.y * 0.5 + 5.0), Vector2(13.0, size.y * 0.5 - 5.0), c, 1.6, true)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(20.0, size.y * 0.5 + 4.5), label(), HORIZONTAL_ALIGNMENT_LEFT, size.x - 22.0, 12, TEXT)
