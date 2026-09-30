class_name SpeechNormalizer
extends RefCounted
## Turns answer text into something a voice reads naturally: markdown and URLs removed, gamer abbreviations and
## numbers expanded, and per-word pronunciation overrides from config (`tts.pronunciations`, e.g.
## {"Cthulhu": "Kuh-thoo-loo"}). Only what is *spoken* changes; the bubble keeps the original text.

const ABBREVIATIONS := {
	"HP": "health points", "MP": "mana points", "SP": "stamina points", "XP": "experience points", "DPS": "damage per second",
	"AoE": "area of effect", "AOE": "area of effect", "DoT": "damage over time", "NPC": "N P C", "NPCs": "N P Cs", "DLC": "D L C",
	"NG+": "new game plus", "PvP": "P v P", "PvE": "P v E", "RNG": "R N G", "UI": "U I", "FPS": "F P S", "RPG": "R P G",
	"vs": "versus", "vs.": "versus", "e.g.": "for example", "i.e.": "that is", "etc.": "and so on", "approx.": "approximately",
	"lvl": "level", "lv.": "level", "esp.": "especially", "incl.": "including", "w/": "with", "w/o": "without", "b/c": "because",
}


static func normalize(text: String, pronunciations: Dictionary = {}) -> String:
	var t := strip_markup(text)
	t = _expand_numbers(t)
	t = _expand_abbreviations(t)
	for word in pronunciations:
		var re := RegEx.new()
		re.compile("(?i)(?<![A-Za-z0-9])" + _escape(str(word)) + "(?![A-Za-z0-9])")
		t = re.sub(t, str(pronunciations[word]), true)
	var ws := RegEx.new()
	ws.compile("[ \\t]+")
	t = ws.sub(t, " ", true).strip_edges()
	return t


## Markdown, links, URLs and list markers out.
static func strip_markup(text: String) -> String:
	var t := text
	var link := RegEx.new()
	link.compile("\\[([^\\]]+)\\]\\([^)]*\\)")
	t = link.sub(t, "$1", true)
	var url := RegEx.new()
	url.compile("(?i)\\(?\\bhttps?://\\S+\\)?")
	t = url.sub(t, "", true)
	for sym in ["**", "__", "`", "~~"]:
		t = t.replace(sym, "")
	var bullets := RegEx.new()
	bullets.compile("(?m)^\\s*(?:[-*•]|#{1,6})\\s+")
	t = bullets.sub(t, "", true)
	t = t.replace("#", "").replace("*", "")
	t = t.replace("\n", " ")
	return t


static func _expand_numbers(t: String) -> String:
	var s := t
	# 1,250 -> 1250 (a voice would pause at the comma)
	var thousands := RegEx.new()
	thousands.compile("(?<=\\d),(?=\\d{3}\\b)")
	s = thousands.sub(s, "", true)
	# 5-15 -> 5 to 15 (only digit ranges, never words like "mini-boss")
	var range_re := RegEx.new()
	range_re.compile("\\b(\\d+(?:\\.\\d+)?)\\s?[-–]\\s?(\\d+(?:\\.\\d+)?)\\b")
	s = range_re.sub(s, "$1 to $2", true)
	# 50% -> 50 percent, +5 -> plus 5, x2 / 2x -> times 2
	var pct := RegEx.new()
	pct.compile("(\\d)\\s?%")
	s = pct.sub(s, "$1 percent", true)
	var plus := RegEx.new()
	plus.compile("(?<![\\w])\\+(\\d)")
	s = plus.sub(s, "plus $1", true)
	s = _replace_times(s)
	s = s.replace(" & ", " and ")
	return s


static func _replace_times(s: String) -> String:
	var a := RegEx.new()
	a.compile("(?i)(?<![\\w])x(\\d+)\\b")
	var b := RegEx.new()
	b.compile("(?i)\\b(\\d+)x(?![\\w])")
	return b.sub(a.sub(s, "times $1", true), "$1 times", true)


static func _expand_abbreviations(t: String) -> String:
	var s := t
	var keys := ABBREVIATIONS.keys()
	keys.sort_custom(func(a, b) -> bool: return str(a).length() > str(b).length())     # "vs." before "vs"
	for abbr in keys:
		var re := RegEx.new()
		# acronyms are case-sensitive ("HP", not "hp"); the lower-case ones (vs, lvl, w/) match as written
		re.compile("(?<![A-Za-z0-9])" + _escape(str(abbr)) + "(?![A-Za-z0-9])")
		s = re.sub(s, str(ABBREVIATIONS[abbr]), true)
	return s


static func _escape(w: String) -> String:
	var out := ""
	for ch in w:
		out += "\\" + ch if ch in ".+*?^$()[]{}|\\/-" else ch
	return out
