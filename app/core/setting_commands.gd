class_name SettingCommands
extends RefCounted
## The "/command" lines of the typed box that change user settings (also the keyboard-only way to reach every
## setting, for accessibility): /opacity /size /corner /captions /autohide /spoilers /text /contrast /game /volume
## /settings. Pure: it validates, updates the UserSettings object and says what happened; Main applies the effect.

const HELP := "Settings: /opacity 20-100 · /size 60-160 (restart) · /corner bottom_right|bottom_left|top_right|top_left · /captions on|off · /autohide seconds|off · /spoilers hint|nudge|full · /text 80-200 · /contrast on|off · /volume 0-100 · /game <profile> · /history · /panic · /settings"

## {handled, ok, message, key, restart}
static func apply(settings: UserSettings, line: String) -> Dictionary:
	var parts := line.strip_edges().split(" ", false)
	if parts.is_empty() or not str(parts[0]).begins_with("/"):
		return {"handled": false}
	var cmd := str(parts[0]).to_lower()
	var arg := str(parts[1]).to_lower() if parts.size() > 1 else ""
	var out := {"handled": true, "ok": true, "message": "", "key": "", "restart": false}
	match cmd:
		"/opacity":
			var f := _percent_or_fraction(arg, 20.0, 100.0)
			return _assign(out, settings, "overlay_opacity", f, "Opacity %d %%." % int(round(f * 100.0)) if f >= 0.0 else "", "Use /opacity 20-100 (percent).")
		"/size":
			var f2 := _percent_or_fraction(arg, 60.0, 160.0)
			var res := _assign(out, settings, "overlay_scale", f2, "Size %d %%. Restart Filo to apply it." % int(round(f2 * 100.0)) if f2 >= 0.0 else "", "Use /size 60-160 (percent).")
			res.restart = res.ok
			return res
		"/corner":
			return _assign(out, settings, "overlay_corner", arg, "Moving to the %s corner." % arg.replace("_", " "), "Use /corner bottom_right, bottom_left, top_right or top_left.")
		"/captions":
			var on = _on_off(arg)
			return _assign(out, settings, "captions", on if on != null else "?", "Captions %s." % ("on: answers stay on screen a few seconds and fade" if on else "off"), "Use /captions on or /captions off.")
		"/autohide":
			var secs := 0
			if arg == "off" or arg == "0":
				secs = 0
			elif arg.is_valid_int():
				secs = int(arg)
			else:
				return _fail(out, "Use /autohide 30 (seconds) or /autohide off.")
			return _assign(out, settings, "auto_hide_seconds", secs, "The controls hide after %d s of inactivity; hover to bring them back." % secs if secs > 0 else "Auto-hide off.", "Use /autohide 30 (seconds) or /autohide off.")
		"/spoilers":
			return _assign(out, settings, "spoiler_level", arg, "Spoiler level: %s." % arg, "Use /spoilers hint, nudge or full.")
		"/text":
			var f3 := _percent_or_fraction(arg, 80.0, 200.0)
			return _assign(out, settings, "text_scale", f3, "Text size %d %%." % int(round(f3 * 100.0)) if f3 >= 0.0 else "", "Use /text 80-200 (percent).")
		"/contrast":
			var hc = _on_off(arg)
			return _assign(out, settings, "high_contrast", hc if hc != null else "?", "High contrast %s." % ("on" if hc else "off"), "Use /contrast on or /contrast off.")
		"/volume":
			if not arg.is_valid_int():
				return _fail(out, "Use /volume 0-100.")
			return _assign(out, settings, "volume", int(arg), "Volume %d." % clampi(int(arg), 0, 100), "Use /volume 0-100.")
		"/game":
			if arg == "":
				return _fail(out, "Use /game sekiro (a folder name under profiles/).")
			return _assign(out, settings, "game", arg, "Game set to %s. Restart Filo to switch its notes." % arg, "Use /game sekiro.")
		"/settings":
			out.message = summary(settings)
			return out
	return {"handled": false}


static func summary(settings: UserSettings) -> String:
	return "opacity %d %% · size %d %% · corner %s · captions %s · auto-hide %s · spoilers %s · text %d %% · contrast %s · volume %d" % [
		int(round(float(settings.get_value("overlay_opacity")) * 100.0)), int(round(float(settings.get_value("overlay_scale")) * 100.0)), str(settings.get_value("overlay_corner")),
		"on" if settings.get_value("captions") else "off", ("%d s" % int(settings.get_value("auto_hide_seconds"))) if int(settings.get_value("auto_hide_seconds")) > 0 else "off",
		str(settings.get_value("spoiler_level")), int(round(float(settings.get_value("text_scale")) * 100.0)), "on" if settings.get_value("high_contrast") else "off", int(settings.get_value("volume"))]


static func _assign(out: Dictionary, settings: UserSettings, key: String, value, message: String, usage: String) -> Dictionary:
	if (typeof(value) == TYPE_FLOAT and value < 0.0) or (typeof(value) == TYPE_STRING and value == "?"):
		return _fail(out, usage)
	if not settings.set_value(key, value):
		return _fail(out, usage)
	out.key = key
	out.message = message
	if not settings.save():
		out.message += " (Could not write settings.json.)"
	return out


static func _fail(out: Dictionary, message: String) -> Dictionary:
	out.ok = false
	out.message = message
	return out


## "70" -> 0.7 and "0.7" -> 0.7 (a bare fraction), -1 when not a number or outside [lo, hi] percent.
static func _percent_or_fraction(arg: String, lo: float, hi: float) -> float:
	if not arg.is_valid_float():
		return -1.0
	var v := float(arg)
	var pct := v * 100.0 if v <= 3.0 else v
	if pct < lo or pct > hi:
		return -1.0
	return pct / 100.0


static func _on_off(arg: String):
	match arg:
		"on", "true", "yes", "1":
			return true
		"off", "false", "no", "0":
			return false
	return null
