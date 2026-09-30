class_name ClickRegion
extends RefCounted
## Which parts of the overlay window take mouse clicks. The window is click-through everywhere
## except over the controls, so the game underneath stays usable.
##
## Why not Window.mouse_passthrough_polygon: Godot applies the polygon in window *pixels* while
## Control rects are in *points* (content_scale_factor = the display's backing scale, 2.0 on a
## Retina Mac), so the old region ended up half the size and in the wrong place: the buttons were
## drawn but every click fell through. Instead Main flips the whole-window mouse_passthrough flag
## each frame from the global cursor position, using this pure, unit-tested geometry.


## Cursor position (screen pixels) -> window-local point coordinates.
static func to_local_points(mouse_px: Vector2, window_px: Vector2, scale: float) -> Vector2:
	return (mouse_px - window_px) / maxf(scale, 0.01)


static func grown(rects: Array, margin: float) -> Array:
	var out := []
	for r in rects:
		out.append((r as Rect2).grow(margin))
	return out


static func contains(rects: Array, point: Vector2, margin: float = 0.0) -> bool:
	for r in rects:
		if (r as Rect2).grow(margin).has_point(point):
			return true
	return false


## True when a click at this cursor position must pass through to the window below.
static func passthrough_at(mouse_px: Vector2, window_px: Vector2, scale: float, rects: Array, margin: float = 6.0) -> bool:
	return not contains(rects, to_local_points(mouse_px, window_px, scale), margin)


## True when `rect` lies completely inside one of the interactive rects (after growing them by margin).
static func covers(rects: Array, rect: Rect2, margin: float = 0.0) -> bool:
	for r in rects:
		if (r as Rect2).grow(margin).encloses(rect):
			return true
	return false
