class_name Easing
extends RefCounted
## The few easing curves the choreography needs, with an adjustable overshoot
## for ease-out-back (Godot's built-in Tween back easing has a fixed overshoot).


static func out_back(x: float, overshoot: float = 1.70158) -> float:
	var c3 := overshoot + 1.0
	var t := x - 1.0
	return 1.0 + c3 * t * t * t + overshoot * t * t


static func in_sine(x: float) -> float:
	return 1.0 - cos(x * PI * 0.5)


static func out_sine(x: float) -> float:
	return sin(x * PI * 0.5)


static func in_quad(x: float) -> float:
	return x * x


static func out_cubic(x: float) -> float:
	var t := 1.0 - x
	return 1.0 - t * t * t
