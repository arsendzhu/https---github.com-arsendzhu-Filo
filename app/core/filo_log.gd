class_name FiloLog
extends RefCounted
## Tiny logger. Every line is prefixed so the demo's stdout is easy to scan.

static var verbose := false


static func info(msg: String) -> void:
	print("[Filo] " + msg)


static func debug(msg: String) -> void:
	if verbose:
		print("[Filo:debug] " + msg)


static func warn(msg: String) -> void:
	print("[Filo:warn] " + msg)


static func error(msg: String) -> void:
	push_error("[Filo] " + msg)
	print("[Filo:error] " + msg)
