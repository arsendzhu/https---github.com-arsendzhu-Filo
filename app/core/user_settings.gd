class_name UserSettings
extends RefCounted
## The one validated file of things the *user* changes while using Filo (as opposed to config.json, which is
## what a developer edits): microphone, hotkeys, volume, voice, overlay opacity/size/position, spoiler level,
## mute state, follow-up mode (voice/typing) and the current game. Lives in <repo>/settings.json (git-ignored).
##
## Every value is validated on load and on set: wrong types fall back to the default, numbers are clamped,
## enums must be one of their choices. A file that is not valid JSON is moved aside to settings.json.corrupt
## and the defaults are used, with a clear log line - Filo never fails to start because of this file.

const VERSION := 1
const SPOILER_LEVELS := ["hint", "nudge", "full"]
const FOLLOWUP_MODES := ["voice", "text"]
const CORNERS := ["bottom_right", "bottom_left", "top_right", "top_left"]

## key -> {type, default, min, max, choices}. The single source of truth for what may be stored.
const SCHEMA := {
	"mic_device": {"type": "string", "default": ""},                       # "" = the system default input
	"hotkey": {"type": "hotkey", "default": {"key": "space", "modifiers": ["option"]}},
	"mute_hotkey": {"type": "hotkey", "default": {"key": "m", "modifiers": ["control", "option"]}},
	"panic_hotkey": {"type": "hotkey", "default": {"key": "h", "modifiers": ["control", "option"]}},
	"volume": {"type": "int", "default": 70, "min": 0, "max": 100},
	"voice": {"type": "string", "default": ""},                            # system voice name(s); "" = config default
	"kokoro_voice": {"type": "string", "default": ""},
	"overlay_opacity": {"type": "float", "default": 1.0, "min": 0.2, "max": 1.0},
	"overlay_scale": {"type": "float", "default": 1.0, "min": 0.6, "max": 1.6},
	"overlay_corner": {"type": "enum", "default": "bottom_right", "choices": CORNERS},
	"overlay_offset": {"type": "vec2", "default": [0.0, 0.0]},             # drag offset from the corner, in points
	"spoiler_level": {"type": "enum", "default": "hint", "choices": SPOILER_LEVELS},
	"mic_muted": {"type": "bool", "default": false},
	"voice_muted": {"type": "bool", "default": false},
	"followup_mode": {"type": "enum", "default": "voice", "choices": FOLLOWUP_MODES},
	"game": {"type": "string", "default": ""},                             # profile id; "" = the config default
	"captions": {"type": "bool", "default": false},
	"auto_hide_seconds": {"type": "int", "default": 0, "min": 0, "max": 3600},
	"text_scale": {"type": "float", "default": 1.0, "min": 0.8, "max": 2.0},
	"high_contrast": {"type": "bool", "default": false},
	"onboarded": {"type": "bool", "default": false},
}

var values := {}
var path := ""
var last_problems: Array = []      # human-readable notes about anything replaced by a default on the last load


func _init() -> void:
	values = defaults()


static func defaults() -> Dictionary:
	var d := {}
	for k in SCHEMA:
		d[k] = SCHEMA[k].default.duplicate(true) if typeof(SCHEMA[k].default) in [TYPE_DICTIONARY, TYPE_ARRAY] else SCHEMA[k].default
	return d


func get_value(key: String):
	return values.get(key, SCHEMA[key].default if SCHEMA.has(key) else null)


## Validated set: returns false (and leaves the value alone) for an unknown key or an invalid value.
func set_value(key: String, value) -> bool:
	if not SCHEMA.has(key):
		return false
	var v := validate(key, value)
	if not v.ok:
		return false
	values[key] = v.value
	return true


## {ok, value}: the value coerced to the schema, or ok=false when it cannot be.
static func validate(key: String, value) -> Dictionary:
	var spec: Dictionary = SCHEMA[key]
	match str(spec.type):
		"bool":
			return {"ok": typeof(value) == TYPE_BOOL, "value": value}
		"string":
			return {"ok": typeof(value) == TYPE_STRING and str(value).length() <= 200, "value": str(value).strip_edges()}
		"int":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or is_nan(float(value)) or is_inf(float(value)):
				return {"ok": false, "value": null}
			return {"ok": true, "value": clampi(int(round(float(value))), int(spec.min), int(spec.max))}
		"float":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or is_nan(float(value)) or is_inf(float(value)):
				return {"ok": false, "value": null}
			return {"ok": true, "value": clampf(float(value), float(spec.min), float(spec.max))}
		"enum":
			return {"ok": typeof(value) == TYPE_STRING and (spec.choices as Array).has(str(value)), "value": value}
		"vec2":
			if typeof(value) == TYPE_ARRAY and value.size() == 2 and typeof(value[0]) in [TYPE_INT, TYPE_FLOAT] and typeof(value[1]) in [TYPE_INT, TYPE_FLOAT]:
				return {"ok": true, "value": [clampf(float(value[0]), -4000.0, 4000.0), clampf(float(value[1]), -4000.0, 4000.0)]}
			return {"ok": false, "value": null}
		"hotkey":
			if typeof(value) == TYPE_DICTIONARY and typeof(value.get("key")) == TYPE_STRING and typeof(value.get("modifiers", [])) == TYPE_ARRAY:
				var mods := []
				for m in value.get("modifiers", []):
					if str(m).to_lower() in ["command", "cmd", "option", "alt", "control", "ctrl", "shift"]:
						mods.append(str(m).to_lower())
				var hk := str(value.key).strip_edges().to_lower()
				return {"ok": hk != "" and hk.length() <= 12, "value": {"key": hk, "modifiers": mods}}
			return {"ok": false, "value": null}
	return {"ok": false, "value": null}


## Loads `file`. A missing file is normal (defaults). A corrupt file is moved to <file>.corrupt.
static func load_from(file: String) -> UserSettings:
	var s := UserSettings.new()
	s.path = file
	if not FileAccess.file_exists(file):
		return s
	var text := FileAccess.get_file_as_string(file)
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		FiloLog.warn("Settings file %s is corrupt (%s) - using the defaults; the broken file was kept as %s.corrupt" % [file.get_file(), json.get_error_message() if json.get_error_message() != "" else "not a JSON object", file.get_file()])
		s.last_problems.append("corrupt file")
		DirAccess.rename_absolute(file, file + ".corrupt")
		return s
	var data: Dictionary = json.data
	for k in data:
		if str(k).begins_with("_"):
			continue
		if not SCHEMA.has(k):
			FiloLog.debug("Settings: ignoring unknown key '%s'" % str(k))
			continue
		var v := validate(str(k), data[k])
		if v.ok:
			s.values[k] = v.value
		else:
			s.last_problems.append("%s: invalid value %s, using %s" % [k, str(data[k]).left(40), str(SCHEMA[k].default)])
			FiloLog.warn("Settings: '%s' has an invalid value (%s) - using the default" % [k, str(data[k]).left(40)])
	return s


## Writes the file atomically (temp file + rename). Returns false on failure (logged, never thrown).
func save(file: String = "") -> bool:
	var target := file if file != "" else path
	if target == "":
		return false
	var out := {"_comment": "Filo user settings (validated on load). Edit while Filo is not running.", "version": VERSION}
	for k in values:
		out[k] = values[k]
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		FiloLog.warn("Could not write the settings file %s (error %d)" % [target, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(out, "  ", true))
	f.close()
	if DirAccess.rename_absolute(tmp, target) != OK:
		DirAccess.remove_absolute(target)
		DirAccess.rename_absolute(tmp, target)
	return true


## Copies the settings that map onto config.json keys into the live config (settings win over config.json).
func apply_to(cfg: FiloConfig) -> void:
	var hk: Dictionary = get_value("hotkey")
	if hk != SCHEMA.hotkey.default:
		cfg.data["hotkey"] = hk.duplicate(true)
	var mh: Dictionary = get_value("mute_hotkey")
	if mh != SCHEMA.mute_hotkey.default:
		cfg.data["hotkey_mute"] = mh.duplicate(true)
	if int(get_value("volume")) != int(SCHEMA.volume.default):
		cfg.data["tts"]["volume"] = int(get_value("volume"))
	if str(get_value("voice")) != "":
		cfg.data["tts"]["voice"] = str(get_value("voice"))
	if str(get_value("kokoro_voice")) != "":
		cfg.data["tts"]["kokoro"]["voice"] = str(get_value("kokoro_voice"))
	if str(get_value("game")) != "":
		cfg.data["default_profile"] = str(get_value("game"))
	if str(get_value("overlay_corner")) != str(SCHEMA.overlay_corner.default):
		cfg.data["overlay"]["corner"] = str(get_value("overlay_corner"))
	cfg.data["settings"] = values.duplicate(true)
