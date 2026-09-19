class_name MascotAnimator
extends Node
## Every mascot animation lives here: a small state machine of tweens on a
## base transform, plus per-frame procedural motion layered on top.
## See docs/animations.md for the full design.
##
##   HIDDEN    invisible (scale 0)
##   WAKING    summon: one full spin while scaling up from nothing and fading in,
##             eyes open right at the end, ease-out-back so it lands with a bounce
##   IDLE      gentle bob + slow sway, random blinks; rests on a rotating
##             "mood" (see register_turn()) so the resting face varies over
##             a conversation without ever settling permanently on one look
##   LISTENING subtle pulse (plus mic level), wider eyes, attentive lean
##   THINKING  slow spin with a head tilt, narrowed eyes glancing up
##   ANSWERING small forward nudge, turns toward the bubble, mouth flaps per word
##   SLEEPING  dismiss: reverse spin while scaling down and fading out,
##             eyes closing part-way, gentle ease-in with no overshoot
##   ERROR     quick head shake, unhappy face, then back to idle

signal state_changed(state: int)
signal wake_finished
signal sleep_finished
signal error_finished

enum State { HIDDEN, WAKING, IDLE, LISTENING, THINKING, ANSWERING, SLEEPING, ERROR }

const WAKE_DURATION := 0.8
const SLEEP_DURATION := 0.62
const SPIN_DEGREES := 360.0
const THINK_SPIN_SPEED := 70.0   # degrees per second

var mascot: Mascot
var state: int = State.HIDDEN
var life := 0.0
var state_time := 0.0

# tweened base transform (choreography and state transitions)
var base_pos := Vector3.ZERO
var base_rot := Vector3.ZERO      # degrees
var base_scale := 0.0001
var alpha := 0.0
var eye_override := 1.0           # multiplies eye openness during wake/sleep
var proc_blend := 0.0             # 0 = no procedural motion, 1 = full

# procedural motion state
var think_spin := 0.0
var level := 0.0
var level_target := 0.0
var mouth_pulse := 0.0
var blink_mult := 1.0
var glint := false

var face: Dictionary = {}
var face_target: Dictionary = {}

var _blink_countdown := 3.0
var _blink_time := -1.0
var _blink_double := false
var _pleased_until := -1.0
var _mood := "idle"              # which FaceSprites.IDLE_MOODS entry idle rests on
var _turns_since_mood_change := 0
var _turns_until_next_mood := 1
var _think_variant := "spin"     # spin | hmm
var _fidget_countdown := 5.0
var _fidget_kind := ""
var _fidget_time := 0.0
var _fidget_dir := 1.0
var _reaction_tween: Tween
var _nod_time := -1.0
var mouth_drive := 0.0           # amplitude-driven mouth (voice envelope)
var _tween: Tween
var _nudge_tween: Tween
var _rng := RandomNumberGenerator.new()


func setup(m: Mascot) -> void:
	mascot = m
	face = FaceSprites.get_sprite("asleep")
	face_target = FaceSprites.get_sprite("asleep")
	_rng.randomize()
	_blink_countdown = _rng.randf_range(2.0, 4.0)
	_apply()


func state_name() -> String:
	return State.keys()[state].to_lower()


func _process(delta: float) -> void:
	life += delta
	state_time += delta
	var k := 1.0 - exp(-delta * 14.0)
	for key in face_target:
		var target = face_target[key]
		if not face.has(key):
			face[key] = target
		elif typeof(target) == TYPE_VECTOR2:
			face[key] = (face[key] as Vector2).lerp(target, k)
		elif typeof(target) == TYPE_INT:
			face[key] = target
		else:
			face[key] = lerpf(float(face[key]), float(target), k)
	if _pleased_until > 0.0 and life >= _pleased_until:
		_pleased_until = -1.0
		if state == State.IDLE:
			face_target = FaceSprites.get_sprite(_mood)
		elif state == State.LISTENING:
			face_target = FaceSprites.get_sprite("listening")
	mouth_drive = lerpf(mouth_drive, 0.0, 1.0 - exp(-delta * 12.0))
	_update_fidget(delta)
	if _nod_time >= 0.0:
		_nod_time += delta
		if _nod_time > 0.42:
			_nod_time = -1.0
	_update_blink(delta)
	level = lerpf(level, level_target, 1.0 - exp(-delta * 12.0))
	level_target = lerpf(level_target, 0.0, 1.0 - exp(-delta * 3.0))
	mouth_pulse = lerpf(mouth_pulse, 0.0, 1.0 - exp(-delta * 9.0))
	var want_proc := 1.0 if state in [State.IDLE, State.LISTENING, State.THINKING, State.ANSWERING, State.ERROR] else 0.0
	proc_blend = lerpf(proc_blend, want_proc, 1.0 - exp(-delta * 6.0))
	if state == State.THINKING:
		think_spin += THINK_SPIN_SPEED * delta
	_apply()


# ---------------------------------------------------------------- public API

## Summon choreography. Ends in IDLE and emits wake_finished.
func wake() -> void:
	if state == State.WAKING:
		return
	_kill_tweens()
	_set_state(State.WAKING)
	think_spin = 0.0
	base_pos = Vector3.ZERO
	base_rot = Vector3.ZERO
	base_scale = 0.0001
	alpha = 0.0
	eye_override = 0.0
	_mood = "idle"
	_turns_since_mood_change = 0
	_turns_until_next_mood = 1
	face = FaceSprites.get_sprite("idle")
	face_target = FaceSprites.get_sprite("idle")
	_tween = create_tween()
	_tween.tween_method(_choreo_wake, 0.0, 1.0, WAKE_DURATION)
	_tween.tween_callback(_on_wake_done)


## Dismiss choreography. Ends in HIDDEN and emits sleep_finished.
func sleep() -> void:
	if state == State.SLEEPING or state == State.HIDDEN:
		return
	_kill_tweens()
	_settle_spin()
	var start_rot := base_rot
	var start_pos := base_pos
	var start_scale := base_scale
	_set_state(State.SLEEPING)
	face_target = FaceSprites.get_sprite("asleep")
	_tween = create_tween()
	_tween.tween_method(_choreo_sleep.bind(start_rot, start_pos, start_scale), 0.0, 1.0, SLEEP_DURATION)
	_tween.tween_callback(_on_sleep_done)


## Switches between the awake states (IDLE, LISTENING, THINKING, ANSWERING).
func set_state(new_state: int) -> void:
	if new_state == state:
		return
	if new_state in [State.HIDDEN, State.WAKING, State.SLEEPING, State.ERROR]:
		push_warning("MascotAnimator: use wake()/sleep()/play_error() for that state")
		return
	if state == State.HIDDEN:
		wake()
		return
	if state in [State.WAKING, State.SLEEPING]:
		return
	var prev := state
	_kill_tweens()
	if prev == State.THINKING:
		_settle_spin()
	_set_state(new_state)
	face_target = FaceSprites.get_sprite(_mood if new_state == State.IDLE else FaceSprites.name_for_state(new_state))
	_pleased_until = -1.0
	if new_state == State.IDLE and prev == State.ANSWERING:
		# a short "^ ^" pleased beat after finishing an answer
		face_target = FaceSprites.get_sprite("pleased")
		_pleased_until = life + 1.4
	_tween = create_tween().set_parallel(true)
	match new_state:
		State.IDLE:
			_tween.tween_property(self, "base_pos", Vector3.ZERO, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			_tween.tween_property(self, "base_rot", Vector3.ZERO, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		State.LISTENING:
			# levitate a little higher while waiting for the player to speak
			_tween.tween_property(self, "base_pos", Vector3(0.0, 0.12, 0.06), 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_tween.tween_property(self, "base_rot", Vector3.ZERO, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			_fidget_countdown = _rng.randf_range(3.0, 6.0)
		State.THINKING:
			think_spin = 0.0
			# variety: the slow spin most of the time, a "hmm" head-tilt otherwise
			_think_variant = "spin" if _rng.randf() < 0.6 else "hmm"
			if _think_variant == "hmm":
				face_target = FaceSprites.get_sprite("thinking_hmm")
			_tween.tween_property(self, "base_pos", Vector3(0.0, 0.05, 0.0), 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_tween.tween_property(self, "base_rot", Vector3.ZERO, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		State.ANSWERING:
			# turn toward the bubble ("directional point") ...
			_tween.tween_property(self, "base_rot", Vector3(0.0, -11.0, 0.0), 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			# ... and a small forward nudge that settles slightly forward while speaking
			_nudge_tween = create_tween()
			_nudge_tween.tween_property(self, "base_pos", Vector3(0.0, 0.0, 0.32), 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_nudge_tween.tween_property(self, "base_pos", Vector3(0.0, 0.0, 0.12), 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Quick head shake + unhappy face, then back to IDLE (emits error_finished).
func play_error() -> void:
	if state in [State.HIDDEN, State.WAKING, State.SLEEPING]:
		return
	_kill_tweens()
	if state == State.THINKING:
		_settle_spin()
	_set_state(State.ERROR)
	face_target = FaceSprites.get_sprite("error")
	_tween = create_tween()
	_tween.tween_property(self, "base_pos", Vector3.ZERO, 0.1)
	for angle in [7.0, -7.0, 5.0, -4.0, 2.0, 0.0]:
		_tween.tween_property(self, "base_rot:z", angle, 0.065).set_trans(Tween.TRANS_SINE)
	_tween.tween_interval(0.75)
	_tween.tween_callback(_on_error_done)


## One mouth flap (call on every spoken word boundary).
func talk_pulse() -> void:
	mouth_pulse = 0.85


## Voice-envelope mouth: 0..1 loudness of the audio being played right now.
func set_mouth_level(level: float) -> void:
	mouth_drive = maxf(mouth_drive, clampf(level, 0.0, 1.0))


## Quick nod (acknowledging "got it").
func nod() -> void:
	if state in [State.HIDDEN, State.WAKING, State.SLEEPING]:
		return
	_nod_time = 0.0


## A little reaction right after an answer: pleased "^ ^", a wink, a hop or a nod.
## Returns the reaction played (so the showcase can force one).
func react_after_answer(kind: String = "") -> String:
	if state in [State.HIDDEN, State.WAKING, State.SLEEPING]:
		return ""
	var options: Array[String] = ["pleased", "wink", "hop", "nod"]
	var chosen: String = kind if kind in options else options[_rng.randi_range(0, options.size() - 1)]
	_pleased_until = life + 1.5
	match chosen:
		"pleased":
			face_target = FaceSprites.get_sprite("pleased")
		"wink":
			face_target = FaceSprites.get_sprite("wink")
			_reaction_tween = create_tween()
			_reaction_tween.tween_property(self, "base_rot:z", 7.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
			_reaction_tween.tween_interval(0.9)
			_reaction_tween.tween_property(self, "base_rot:z", 0.0, 0.3).set_trans(Tween.TRANS_SINE)
		"hop":
			face_target = FaceSprites.get_sprite("pleased")
			var rest := base_pos
			_reaction_tween = create_tween()
			_reaction_tween.tween_property(self, "base_pos:y", rest.y + 0.28, 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			_reaction_tween.tween_property(self, "base_pos:y", rest.y, 0.22).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		"nod":
			face_target = FaceSprites.get_sprite("pleased")
			_nod_time = 0.0
	return chosen


## Call once per completed answer (see Main._ask()). Rotates which named
## expression IDLE rests on roughly every 1-2 questions — enough to feel
## alive over a longer conversation without ever reading as stuck on one
## look; "idle", the original look, stays in the roster so it keeps coming
## back, it's just no longer the only thing shown at rest.
func register_turn() -> void:
	_turns_since_mood_change += 1
	if _turns_since_mood_change >= _turns_until_next_mood:
		_advance_mood()


func _advance_mood() -> void:
	_turns_since_mood_change = 0
	_turns_until_next_mood = 1 if _rng.randf() < 0.5 else 2
	var choices := FaceSprites.IDLE_MOODS.duplicate()
	choices.erase(_mood)
	if choices.is_empty():
		choices = FaceSprites.IDLE_MOODS.duplicate()
	_mood = choices[_rng.randi_range(0, choices.size() - 1)]
	if state == State.IDLE and _pleased_until < 0.0:
		face_target = FaceSprites.get_sprite(_mood)


## The sprite name IDLE/LISTENING are actually resting on right now (IDLE
## rotates through moods; every other state has one fixed, clear sprite).
func _resting_sprite_name() -> String:
	if state == State.IDLE:
		return _mood
	return FaceSprites.name_for_state(state)


## "bye filo": a happy little hop with closed-smile eyes before spinning out.
func play_farewell() -> void:
	if state in [State.HIDDEN, State.WAKING, State.SLEEPING]:
		return
	_kill_tweens()
	_set_state(State.IDLE)
	face_target = FaceSprites.get_sprite("pleased")
	_pleased_until = life + 3.0
	_reaction_tween = create_tween()
	_reaction_tween.tween_property(self, "base_pos", Vector3(0.0, 0.22, 0.0), 0.16).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_reaction_tween.tween_property(self, "base_pos", Vector3.ZERO, 0.3).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_reaction_tween.tween_property(self, "base_rot:z", 8.0, 0.2).set_trans(Tween.TRANS_SINE)
	_reaction_tween.tween_property(self, "base_rot:z", -8.0, 0.35).set_trans(Tween.TRANS_SINE)
	_reaction_tween.tween_property(self, "base_rot:z", 0.0, 0.25).set_trans(Tween.TRANS_SINE)


# ---------------------------------------------------------------- fidgets

## Secondary idle animations at random intervals so the base loop never
## reads as mechanical: a glance to the side, a stretch, a head tilt, a double blink.
func _update_fidget(delta: float) -> void:
	if _fidget_kind != "":
		_fidget_time += delta
		var done := false
		match _fidget_kind:
			"look":
				done = _fidget_time > 1.4
				if done:
					face_target["eye_shift"] = FaceSprites.get_sprite(_resting_sprite_name()).get("eye_shift", Vector2.ZERO)
			"stretch":
				done = _fidget_time > 0.5
			"tilt":
				done = _fidget_time > 1.3
			"eartilt":
				done = _fidget_time > 1.0
			_:
				done = true
		if done:
			_fidget_kind = ""
			_fidget_countdown = _rng.randf_range(4.0, 9.0) if state == State.IDLE else _rng.randf_range(3.5, 7.0)
		return
	if state != State.IDLE and state != State.LISTENING:
		return
	if _pleased_until > 0.0:
		return
	_fidget_countdown -= delta
	if _fidget_countdown > 0.0:
		return
	_fidget_time = 0.0
	_fidget_dir = 1.0 if _rng.randf() < 0.5 else -1.0
	if state == State.LISTENING:
		_fidget_kind = "eartilt"
		return
	var roll := _rng.randf()
	if roll < 0.4:
		_fidget_kind = "look"
		face_target["eye_shift"] = Vector2(0.09 * _fidget_dir, 0.02)
	elif roll < 0.6:
		_fidget_kind = "stretch"
	elif roll < 0.85:
		_fidget_kind = "tilt"
	else:
		_fidget_kind = "blink2"
		_blink_time = 0.0
		_blink_double = true


func _fidget_offsets() -> Dictionary:
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO
	var scl := Vector3.ONE
	match _fidget_kind:
		"stretch":
			var s := sin(clampf(_fidget_time / 0.5, 0.0, 1.0) * PI)
			scl = Vector3(1.0 - 0.04 * s, 1.0 + 0.07 * s, 1.0 - 0.04 * s)
			pos.y = 0.03 * s
		"tilt":
			var t := clampf(_fidget_time / 1.3, 0.0, 1.0)
			rot.z = 6.0 * _fidget_dir * sin(t * PI)
		"eartilt":
			var t := clampf(_fidget_time / 1.0, 0.0, 1.0)
			rot.z = 9.0 * _fidget_dir * sin(t * PI)
			rot.y = 4.0 * _fidget_dir * sin(t * PI)
	if _nod_time >= 0.0:
		rot.x += 9.0 * sin(clampf(_nod_time / 0.42, 0.0, 1.0) * TAU)
	return {"pos": pos, "rot": rot, "scl": scl}


## Microphone level 0..1 while listening (drives the pulse amplitude).
func set_level(v: float) -> void:
	level_target = maxf(level_target, clampf(v, 0.0, 1.0))


## The always-visible screen-reading cue: a small glint in the eyes.
func set_glint(on: bool) -> void:
	glint = on


func trigger_blink() -> void:
	_blink_time = 0.0
	_blink_double = false


## Keeps the eyes open for a while (used by the showcase captures).
func hold_blink(seconds: float) -> void:
	_blink_time = -1.0
	blink_mult = 1.0
	_blink_countdown = maxf(_blink_countdown, seconds)


# ------------------------------------------------------------- choreography

func _choreo_wake(p: float) -> void:
	base_scale = maxf(Easing.out_back(p, 1.55), 0.0001)
	base_rot.y = SPIN_DEGREES * (1.0 - Easing.out_back(p, 0.8))
	alpha = Easing.out_sine(clampf(p / 0.6, 0.0, 1.0))
	eye_override = clampf(Easing.out_back(clampf((p - 0.78) / 0.16, 0.0, 1.0), 1.7), 0.0, 1.25)


func _choreo_sleep(p: float, start_rot: Vector3, start_pos: Vector3, start_scale: float) -> void:
	var q := Easing.in_sine(p)
	base_scale = maxf(start_scale * (1.0 - q), 0.0001)
	base_rot = start_rot.lerp(Vector3.ZERO, q)
	base_rot.y -= SPIN_DEGREES * q
	base_pos = start_pos.lerp(Vector3.ZERO, q)
	alpha = 1.0 - clampf((p - 0.4) / 0.6, 0.0, 1.0)
	eye_override = 1.0 - clampf((p - 0.22) / 0.2, 0.0, 1.0)


func _on_wake_done() -> void:
	base_scale = 1.0
	base_rot = Vector3.ZERO
	base_pos = Vector3.ZERO
	alpha = 1.0
	eye_override = 1.0
	_set_state(State.IDLE)
	face_target = FaceSprites.get_sprite("idle")
	wake_finished.emit()


func _on_sleep_done() -> void:
	base_scale = 0.0001
	alpha = 0.0
	base_rot = Vector3.ZERO
	base_pos = Vector3.ZERO
	eye_override = 1.0
	_set_state(State.HIDDEN)
	sleep_finished.emit()


func _on_error_done() -> void:
	error_finished.emit()
	if state == State.ERROR:
		_set_state(State.IDLE)
		face_target = FaceSprites.get_sprite(_mood)
		_tween = create_tween()
		_tween.tween_property(self, "base_rot", Vector3.ZERO, 0.2)


## Moves the accumulated thinking spin into base_rot (shortest way round) so the
## follow-up transition can smoothly bring the face back to the front.
func _settle_spin() -> void:
	if think_spin == 0.0:
		return
	var y := fmod(think_spin, 360.0)
	if y > 180.0:
		y -= 360.0
	base_rot.y += y * proc_blend
	think_spin = 0.0


func _set_state(s: int) -> void:
	state = s
	state_time = 0.0
	state_changed.emit(s)


func _kill_tweens() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	if _nudge_tween and _nudge_tween.is_valid():
		_nudge_tween.kill()


# ------------------------------------------------------------ per-frame apply

func _update_blink(delta: float) -> void:
	if _blink_time >= 0.0:
		_blink_time += delta
		var d := 0.16
		if _blink_time < d:
			blink_mult = 1.0 - sin(_blink_time / d * PI)
		elif _blink_double and _blink_time < d * 2.0:
			blink_mult = 1.0 - sin((_blink_time - d) / d * PI)
		else:
			blink_mult = 1.0
			_blink_time = -1.0
			_blink_countdown = _rng.randf_range(2.4, 5.2)
	elif state in [State.IDLE, State.LISTENING, State.ANSWERING]:
		_blink_countdown -= delta
		if _blink_countdown <= 0.0:
			_blink_time = 0.0
			_blink_double = _rng.randf() < 0.2
	else:
		blink_mult = lerpf(blink_mult, 1.0, 1.0 - exp(-delta * 10.0))


func _apply() -> void:
	if mascot == null:
		return
	var pos := base_pos
	var rot := base_rot
	var scl := Vector3.ONE * base_scale
	var p := proc_blend
	match state:
		State.IDLE:
			pos.y += sin(life * TAU / 2.4) * 0.06 * p
			rot.z += sin(life * TAU / 5.3) * 2.0 * p
			rot.y += sin(life * TAU / 7.1) * 4.0 * p
		State.LISTENING:
			var pulse := 1.0 + (sin(life * TAU / 0.9) * 0.02 + level * 0.07) * p
			scl *= pulse
			pos.y += sin(life * TAU / 3.2) * 0.05 * p    # gentle levitation
			rot.y += sin(life * TAU / 6.5) * 3.0 * p
			rot.x += -6.0 * p
		State.THINKING:
			if _think_variant == "hmm":
				rot.z += 10.0 * p
				rot.x += sin(life * TAU / 1.8) * 3.0 * p
				pos.y += sin(life * TAU / 1.8) * 0.02 * p
			else:
				rot.y += think_spin * p
				rot.z += 8.0 * p
				pos.y += sin(life * TAU / 1.6) * 0.03 * p
		State.ANSWERING:
			pos.y += sin(life * TAU / 1.3) * 0.035 * p
			rot.z += sin(life * TAU / 1.3) * 1.5 * p
		State.ERROR:
			pos.y += sin(life * TAU / 2.4) * 0.03 * p
		_:
			pass
	var fo := _fidget_offsets()
	pos += fo.pos * p
	rot += fo.rot * p
	scl *= fo.scl
	mascot.pivot.position = pos
	mascot.pivot.rotation_degrees = rot
	mascot.pivot.scale = scl
	mascot.set_alpha(alpha)
	var height := clampf(pos.y + 0.06, 0.0, 0.6)
	var shadow_scale := clampf(scl.x * (1.0 - height * 0.9), 0.0001, 2.0)
	mascot.set_shadow(shadow_scale, clampf(0.6 * (1.0 - height * 1.4) * alpha, 0.0, 1.0))
	var eye_open: float = float(face.get("eye_open", 1.0)) * blink_mult * eye_override
	var mouth_open: float = clampf(float(face.get("mouth_open", 0.0)) + maxf(mouth_pulse, mouth_drive), 0.0, 1.0)
	mascot.set_face(face, eye_open, mouth_open, glint)
