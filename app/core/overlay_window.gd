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
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var w_pts: float = float(cfg.get_value("overlay.width", 620))
	var h_pts: float = float(cfg.get_value("overlay.height", 420))
	var margin_pts: float = float(cfg.get_value("overlay.margin", 24))
	var size_px := Vector2i(roundi(w_pts * scale), roundi(h_pts * scale))
	var margin_px := roundi(margin_pts * scale)

	window.borderless = true
	window.transparent = true
	window.always_on_top = true
	window.unresizable = true
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
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
	window.position = pos
	set_passthrough(window, true)
	FiloLog.info("Overlay window: %dx%d px at %s (scale %.1f, screen usable %s)" % [size_px.x, size_px.y, str(pos), scale, str(usable)])
	return {"scale": scale, "size_px": size_px, "size_pts": Vector2(w_pts, h_pts)}


## Click-through + never-focused when true (normal overlay mode). False while the
## typed-question panel is open so the player can click and type into it.
static func set_passthrough(window: Window, enabled: bool) -> void:
	window.mouse_passthrough = enabled
	window.unfocusable = enabled
