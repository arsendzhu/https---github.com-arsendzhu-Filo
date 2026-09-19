class_name FaceSprites
extends RefCounted
## The mascot's face is a handful of swappable eye/mouth sprite pairs, one per
## state or mood. Each pair is data (shader parameters in face-local units,
## where 1.0 is the half-width of the flat front face) rather than deformed
## geometry, rasterised inside the same low-resolution palette pipeline as
## the body.
##
## Design rules (see docs/animations.md): big round-ish eyes with a shine dot,
## set wide apart and at mid-face; a tiny mouth just below the eyes; soft blush.
##
##   eye_center    where the right eye sits (left is mirrored)
##   eye_size      half extents of the eyes (slightly wider than tall)
##   eye_open      0 closed line .. 1 fully open
##   eye_shift     glance offset applied to both eyes
##   eye_style     0 oval, 1 happy "^ ^" arch
##   eye_highlight radius of the shine dot (0 = none)
##   eye_asym      per-eye openness multiplier (x=left, y=right; 1,1 = symmetric)
##   mouth_style   0 smile line, 1 "w" cat mouth (mouth_open > 0 draws an open oval instead)
##   mouth_x/y     mouth position
##   mouth_width   half width of the mouth
##   mouth_open    0 line .. 1 open oval (talking pulses add on top)
##   mouth_curve   corner lift: + smile, - frown
##   blush         cheek tint 0..1
##
## Every sprite name below resolves to the FULL key set (BASE merged with its
## own overrides) — deliberately, so the per-frame lerp in MascotAnimator._process()
## (which only walks the keys present in the *target* dictionary) always has
## something to animate every field back to. A sprite that silently omitted a
## key — as "wink" alone used to omit eye_asym from every other sprite — left
## that field stuck wherever it last landed instead of ever easing home; that
## was the "stuck with one eye closed" bug. Never add a new field to just one
## entry below: add it to BASE (with the neutral default) first.

const BASE := {
	"eye_center": Vector2(0.40, 0.08), "eye_size": Vector2(0.24, 0.20), "eye_open": 1.0, "eye_shift": Vector2(0.0, 0.0),
	"eye_style": 0, "eye_highlight": 0.07, "eye_asym": Vector2(1.0, 1.0),
	"mouth_style": 0, "mouth_x": 0.0, "mouth_y": -0.26, "mouth_width": 0.11, "mouth_open": 0.0, "mouth_curve": 0.12,
	"blush": 0.3,
}

## Only the deltas from BASE. Functional states (listening/thinking/answering/
## asleep/error) plus the transient post-answer reactions (pleased/wink) and
## the idle "mood" roster (curious/focused/cute — idle itself is BASE as-is).
const OVERRIDES := {
	"idle": {},
	"listening": {
		"eye_center": Vector2(0.40, 0.09), "eye_size": Vector2(0.26, 0.23), "eye_shift": Vector2(0.0, 0.02), "eye_highlight": 0.08,
		"mouth_y": -0.27, "mouth_width": 0.075, "mouth_open": 0.45, "mouth_curve": 0.0,
		"blush": 0.7,
	},
	"thinking": {
		"eye_open": 0.55, "eye_shift": Vector2(0.06, 0.10), "eye_highlight": 0.06,
		"mouth_x": 0.06, "mouth_y": -0.25, "mouth_width": 0.08, "mouth_curve": -0.03,
		"blush": 0.15,
	},
	"thinking_hmm": {
		"eye_open": 0.7, "eye_shift": Vector2(-0.07, 0.10), "eye_highlight": 0.06,
		"mouth_x": -0.07, "mouth_y": -0.25, "mouth_width": 0.07, "mouth_curve": -0.02,
		"blush": 0.15,
	},
	"answering": {
		"eye_center": Vector2(0.40, 0.08),
		"mouth_width": 0.12, "mouth_open": 0.15, "mouth_curve": 0.08,
		"blush": 0.5,
	},
	"pleased": {
		"eye_center": Vector2(0.40, 0.09), "eye_style": 1, "eye_highlight": 0.0,
		"mouth_style": 1, "mouth_width": 0.13,
		"blush": 0.7,
	},
	"wink": {
		"eye_center": Vector2(0.40, 0.09), "eye_asym": Vector2(1.0, 0.0),
		"mouth_x": 0.04, "mouth_width": 0.13, "mouth_curve": 0.14,
		"blush": 0.55,
	},
	"asleep": {
		"eye_open": 0.0, "eye_highlight": 0.0,
		"mouth_width": 0.08, "mouth_curve": 0.08,
		"blush": 0.2,
	},
	"error": {
		"eye_center": Vector2(0.40, 0.06), "eye_open": 0.45, "eye_shift": Vector2(0.0, -0.03), "eye_highlight": 0.05,
		"mouth_y": -0.30, "mouth_curve": -0.14,
		"blush": 0.1,
	},
	# --- idle "mood" roster: MascotAnimator.register_turn() rotates through
	# these (plus plain "idle") roughly every 1-2 answered questions, only
	# ever while actually resting (idle), so listening/thinking/answering
	# keep their own clear, unambiguous expressions.
	"curious": {
		"eye_size": Vector2(0.25, 0.21), "eye_shift": Vector2(0.09, 0.05), "eye_highlight": 0.09,
		"mouth_width": 0.08, "mouth_open": 0.22, "mouth_curve": 0.05,
		"blush": 0.35,
	},
	"focused": {
		"eye_open": 0.72, "eye_highlight": 0.05,
		"mouth_width": 0.09, "mouth_curve": -0.02,
		"blush": 0.15,
	},
	"cute": {
		"eye_size": Vector2(0.27, 0.23), "eye_highlight": 0.09,
		"mouth_curve": 0.16,
		"blush": 0.65,
	},
}

## The idle mood roster (see MascotAnimator.register_turn()). "idle" — the
## original, most-loved look — is included so it keeps coming back often;
## it is never permanently excluded, just one of several.
const IDLE_MOODS: Array[String] = ["idle", "curious", "focused", "cute", "pleased"]


static func get_sprite(sprite_name: String) -> Dictionary:
	var d := BASE.duplicate(true)
	var over: Dictionary = OVERRIDES.get(sprite_name, {})
	for k in over:
		d[k] = over[k]
	return d


static func name_for_state(state: int) -> String:
	match state:
		MascotAnimator.State.LISTENING:
			return "listening"
		MascotAnimator.State.THINKING:
			return "thinking"
		MascotAnimator.State.ANSWERING:
			return "answering"
		MascotAnimator.State.ERROR:
			return "error"
		MascotAnimator.State.HIDDEN, MascotAnimator.State.SLEEPING:
			return "asleep"
		_:
			return "idle"
