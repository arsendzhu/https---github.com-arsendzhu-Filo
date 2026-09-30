class_name SentenceStreamer
extends RefCounted
## Finds the first complete sentence in text that is still arriving (streamed model output), so speech can
## start before the whole answer exists. A sentence is complete when its terminator (. ! ?) is followed by
## whitespace (so "3.5" or "Dr. Smith" do not end it) and it has at least `min_words` words (so a
## preface like "Let me check." is not spoken). Thinking blocks are ignored, an unfinished one holds
## everything back. Also splits finished text into sentences for the TTS text normalizer.

const ABBREVIATIONS := ["dr", "mr", "mrs", "ms", "vs", "etc", "e.g", "i.e", "st", "no", "approx", "lvl", "jr", "sr"]

var min_words := 6
var on_first := Callable()            # func(sentence: String)
var emitted := false
var head := ""
var _buf := ""


func _init(first_callback: Callable = Callable(), words: int = 6) -> void:
	on_first = first_callback
	min_words = words


func feed(delta: String) -> void:
	if emitted:
		return
	_buf += delta
	if _buf.contains("<think") and not _buf.contains("</think>"):
		return                          # still thinking: nothing to say yet
	var text := NimClient.strip_thinking(_buf)
	# complete sentences so far; the head is as many of them as it takes to reach min_words
	var candidate := ""
	var rest := text
	while true:
		var s := first_sentence(rest)
		if s == "":
			return
		candidate = (candidate + " " + s).strip_edges()
		rest = rest.substr(rest.find(s) + s.length()).strip_edges()
		if _word_count(candidate) >= min_words:
			break
	emitted = true
	head = ResearchAgent.clean_answer(candidate)
	if head != "" and on_first.is_valid():
		on_first.call(head)


## The first sentence of `text` that is *known* to be complete ("" if the terminator has not been followed by
## whitespace yet).
static func first_sentence(text: String) -> String:
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if ch == "." or ch == "!" or ch == "?":
			var next := text[i + 1] if i + 1 < n else ""
			if next != "" and (next == " " or next == "\n" or next == "\t"):
				var candidate := text.substr(0, i + 1).strip_edges()
				if not _is_abbreviation(candidate) and not _is_decimal(text, i):
					return candidate
		i += 1
	return ""


## All sentences of a finished text (the last one needs no following whitespace).
static func split_sentences(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var rest := text.strip_edges()
	while rest != "":
		var s := first_sentence(rest)
		if s == "":
			out.append(rest)
			break
		out.append(s)
		rest = rest.substr(s.length()).strip_edges()
	return out


static func _word_count(s: String) -> int:
	return s.split(" ", false).size()


static func _is_abbreviation(candidate: String) -> bool:
	var last := candidate.strip_edges().rstrip(".!?").split(" ", false)
	if last.is_empty():
		return false
	var word := str(last[last.size() - 1]).to_lower()
	return ABBREVIATIONS.has(word) or (word.length() == 1 and word != "i" and word != "a")


static func _is_decimal(text: String, dot: int) -> bool:
	return text[dot] == "." and dot > 0 and dot + 1 < text.length() and text[dot - 1].is_valid_int() and text[dot + 1].is_valid_int()
