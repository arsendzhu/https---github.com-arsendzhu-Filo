class_name OverlayWindow
extends RefCounted
## Turns the main Godot window into a transparent, borderless, always-on-top,
## click-through overlay parked in a screen corner. All sizes in config are in
## points; Godot on macOS works in physical pixels, so we scale by the screen's
## backing scale and use content_scale_factor so UI code can think in points.


static func setup(window: Window, cfg: FiloConfig) -> Dictionary:
	var screen := DisplayServer.window_get_current_screen()
	var scale := DisplayServer.screen_get_scale(screen)
	if scale <= 0.0:
		scale = 1.0
	window.borderless = true
	window.transparent = true
	window.always_on_top = true
	window.unresizable = true
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var info := apply_scale(window, cfg, scale)
	set_passthrough(window, true)
	return info


## (Re)sizes and parks the window for a display scale. Sizes in config are points, the window is in
## physical pixels. Used at start-up and whenever the window lands on a display with another scale.
static func apply_scale(window: Window, cfg: FiloConfig, scale: float) -> Dictionary:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var w_pts: float = float(cfg.get_value("overlay.width", 620))
	var h_pts: float = float(cfg.get_value("overlay.height", 420))
	var margin_pts: float = float(cfg.get_value("overlay.margin", 24))
	var size_px := Vector2i(roundi(w_pts * scale), roundi(h_pts * scale))
	var margin_px := roundi(margin_pts * scale)
	window.content_scale_factor = scale
	window.size = size_px
	var pos := usable.position + usable.size - size_px - Vector2i(margin_px, margin_px)
	match str(cfg.get_value("overlay.corner", "bottom_right")):
		"bottom_left":
			pos.x = usable.position.x + margin_px
		"top_right":
			pos.y = usable.position.y + margin_px
		"top_left":
			pos.x = usable.position.x + margin_px
			pos.y = usable.position.y + margin_px
	var offset = cfg.get_value("overlay.offset", [0.0, 0.0])
	if typeof(offset) == TYPE_ARRAY and offset.size() == 2:
		pos += Vector2i(roundi(float(offset[0]) * scale), roundi(float(offset[1]) * scale))
	pos = clamp_to_screen(pos, size_px, usable)
	window.position = pos
	FiloLog.info("Overlay window: %dx%d px at %s (scale %.1f, screen usable %s)" % [size_px.x, size_px.y, str(pos), scale, str(usable)])
	return {"scale": scale, "size_px": size_px, "size_pts": Vector2(w_pts, h_pts)}


## Where a dragged window ends up: snapped to the nearest screen corner when it is within `threshold_px` of one,
## otherwise kept where it is (clamped on screen) and remembered as an offset from the nearest corner.
## {corner, offset (points), pos (px), snapped}
static func snap_position(pos: Vector2i, size_px: Vector2i, usable: Rect2i, margin_px: int, threshold_px: int, scale: float) -> Dictionary:
	var anchors := {
		"top_left": Vector2i(usable.position.x + margin_px, usable.position.y + margin_px),
		"top_right": Vector2i(usable.end.x - size_px.x - margin_px, usable.position.y + margin_px),
		"bottom_left": Vector2i(usable.position.x + margin_px, usable.end.y - size_px.y - margin_px),
		"bottom_right": Vector2i(usable.end.x - size_px.x - margin_px, usable.end.y - size_px.y - margin_px),
	}
	var best := "bottom_right"
	var best_d := INF
	for k in anchors:
		var d := Vector2(pos - anchors[k]).length()
		if d < best_d:
			best_d = d
			best = k
	if best_d <= float(threshold_px):
		return {"corner": best, "offset": [0.0, 0.0], "pos": anchors[best], "snapped": true}
	var clamped := clamp_to_screen(pos, size_px, usable)
	var off := Vector2(clamped - anchors[best]) / maxf(scale, 0.01)
	return {"corner": best, "offset": [off.x, off.y], "pos": clamped, "snapped": false}


## Keeps the window (at least mostly) on the screen after a saved offset or a display change.
static func clamp_to_screen(pos: Vector2i, size_px: Vector2i, usable: Rect2i) -> Vector2i:
	if usable.size.x <= 0 or usable.size.y <= 0:
		return pos
	var keep := 120     # px of the window that must stay visible
	return Vector2i(clampi(pos.x, usable.position.x - size_px.x + keep, usable.end.x - keep), clampi(pos.y, usable.position.y - size_px.y + keep, usable.end.y - keep))


## Click-through + never-focused when true (normal overlay mode). False while the
## typed-question panel is open so the player can click and type into it.
static func set_passthrough(window: Window, enabled: bool) -> void:
	window.mouse_passthrough = enabled
	window.unfocusable = enabled
