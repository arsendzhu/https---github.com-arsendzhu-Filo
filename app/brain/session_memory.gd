class_name SessionMemory
extends RefCounted
## Short-term conversation state: the current game, the last few turns and what the last question
## was about, so "what about the second phase?" resolves. Cleared when the game changes or after a
## long idle gap. Pure data + a clock hook, so it is trivially testable.

var game := ""
var turns: Array = []          # [{q, a, topic}] oldest first
var max_turns := 4
var idle_reset_seconds := 900.0
var last_active := -1.0
var clock := Callable()        # optional func() -> float seconds (tests)
var last_question := ""        # the last factual question and the spoiler level it was answered at ("tell me more")
var last_level := ""


func _now() -> float:
	return float(clock.call()) if clock.is_valid() else Time.get_ticks_msec() / 1000.0


## Call at the start of every question. Returns why the memory was cleared ("" when it was kept).
func begin_question(question_game: String) -> String:
	var now := _now()
	var reason := ""
	if last_active >= 0.0 and idle_reset_seconds > 0.0 and now - last_active > idle_reset_seconds:
		reason = "idle for %d s" % int(now - last_active)
	elif question_game != "" and game != "" and not QueryRouter.same_game(question_game, game):
		reason = "game changed from '%s' to '%s'" % [game, question_game]
	if reason != "":
		turns.clear()
		game = ""
		last_question = ""
		last_level = ""
	if question_game != "":
		game = question_game
	last_active = now
	return reason


func note_turn(question: String, answer: String, topic: String) -> void:
	if max_turns <= 0:
		return
	turns.append({"q": question, "a": answer, "topic": topic})
	while turns.size() > max_turns:
		turns.pop_front()
	last_active = _now()


func last_topic() -> String:
	for i in range(turns.size() - 1, -1, -1):
		var t := str(turns[i].get("topic", ""))
		if t != "":
			return t
	return ""


func clear() -> void:
	last_question = ""
	last_level = ""
	turns.clear()
	game = ""
	last_active = -1.0


## What goes into the prompt as "Session context".
func context() -> Dictionary:
	var d := {}
	if game != "":
		d["game"] = game
	if last_topic() != "":
		d["last_topic"] = last_topic()
	return d
