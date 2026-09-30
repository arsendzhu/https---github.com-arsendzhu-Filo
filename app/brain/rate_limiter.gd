class_name RateLimiter
extends RefCounted
## Client-side request pacing for the free NIM tier (about 40 requests a minute): a sliding one-minute
## window. `acquire()` returns at once when there is room, otherwise waits just long enough, so a burst of
## tool-loop requests is spread out instead of being answered with HTTP 429. Optionally a hard budget for
## the whole process (used by the live benchmark so it can never exceed its request allowance).

var max_per_minute := 35
var budget := 0                       # 0 = unlimited; otherwise the total number of requests this process may make
var used := 0
var clock := Callable()               # func() -> float seconds (tests)
var sleeper := Callable()             # func(seconds) coroutine (tests); default: a SceneTree timer
var waited_total := 0.0
var _stamps: Array = []               # times of the requests in the last minute
var _tree: SceneTree


func _init(per_minute: int = 35, tree: SceneTree = null) -> void:
	max_per_minute = per_minute
	_tree = tree if tree != null else (Engine.get_main_loop() as SceneTree)


func _now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0


## Seconds a request would have to wait right now (0 = go).
func wait_needed() -> float:
	if max_per_minute <= 0:
		return 0.0
	var now := _now()
	while not _stamps.is_empty() and now - float(_stamps[0]) >= 60.0:
		_stamps.pop_front()
	if _stamps.size() < max_per_minute:
		return 0.0
	return maxf(0.0, 60.0 - (now - float(_stamps[0])) + 0.05)


func budget_left() -> int:
	return 999999 if budget <= 0 else maxi(0, budget - used)


## True when the request may go out (after waiting for room). False = the process budget is spent.
func acquire() -> bool:
	if budget > 0 and used >= budget:
		return false
	var wait := wait_needed()
	if wait > 0.0:
		waited_total += wait
		FiloLog.info("NIM: pacing requests (%.1f s wait, limit %d/min)" % [wait, max_per_minute])
		if sleeper.is_valid():
			await sleeper.call(wait)
		elif _tree != null:
			await _tree.create_timer(wait).timeout
		wait_needed()   # drops the expired stamps
	_stamps.append(_now())
	used += 1
	return true
