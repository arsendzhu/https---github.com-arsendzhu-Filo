class_name TermCorrector
extends RefCounted
## Repairs game terms a speech recogniser mis-heard ("Cliff" -> "Kliff", "Unka's" -> "Oongka's"), using the
## current game's vocabulary. Rule-based and offline, so it costs nothing and cannot add latency.
##
## A word or short phrase is replaced by a vocabulary term only when the two are close in spelling
## (edit distance) or sound (a consonant skeleton), and never when the text is an ordinary lower-case
## English word: "the cliff" and "a skeleton" stay, a capitalised mid-sentence "Cliff" is a name and
## may become "Kliff". Very short terms (Owl, Sif, Emma) are only re-cased, never fuzzy matched.

const COMMON := [
	"a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "with", "from", "by", "about", "is", "are", "was", "were",
	"be", "do", "does", "did", "i", "me", "my", "we", "you", "your", "it", "its", "that", "this", "what", "which", "who", "how",
	"where", "when", "why", "can", "could", "should", "would", "will", "get", "got", "find", "beat", "kill", "defeat", "reach",
	"use", "make", "need", "want", "know", "tell", "give", "take", "go", "see", "have", "has", "had", "not", "no", "yes", "there",
	"here", "then", "than", "them", "they", "their", "he", "she", "his", "her", "him", "up", "down", "out", "into", "over",
	"boss", "item", "weapon", "weapons", "armor", "level", "quest", "map", "key", "role", "best", "first", "second", "third",
	"phase", "camp", "guide", "blade", "shrine", "flask", "reed", "devil", "mortal", "sword", "saint", "lord", "wall", "flesh",
	"queen", "king", "moon", "brain", "eye", "eater", "worlds", "world", "golem", "owl", "great", "headless", "monk", "temple",
	"castle", "palace", "estate", "dragon", "serpent", "sculptor", "demon", "hatred", "abyss", "artifact", "desert", "crimson",
	"dark", "souls", "shadows", "die", "twice",
]
const MIN_FUZZY_LEN := 5


## {text, changes: [[from, to], ...]}. `terms` is the current game's vocabulary.
static func correct(text: String, terms: PackedStringArray) -> Dictionary:
	var out := {"text": text, "changes": []}
	if text.strip_edges() == "" or terms.is_empty():
		return out
	var tokens := _tokens(text)
	if tokens.is_empty():
		return out
	var cands := []
	for t in terms:
		var words := _words(t)
		if words.is_empty():
			continue
		cands.append({"term": t, "n": words.size(), "flat": _letters(t), "skel": skeleton(t), "lower": str(t).to_lower()})
	var edits := []      # [start_char, end_char, replacement, original]
	var i := 0
	while i < tokens.size():
		var best := {}
		for n in [4, 3, 2, 1]:
			if i + n > tokens.size():
				continue
			var span := _span_text(text, tokens, i, n)
			var m := _best_match(span, tokens, i, n, cands)
			if not m.is_empty():
				best = m
				best["n"] = n
				break
		if best.is_empty():
			i += 1
			continue
		var n: int = best.n
		var start: int = tokens[i].start
		var end: int = tokens[i + n - 1].end
		var original := text.substr(start, end - start)
		if original != best.term:
			edits.append([start, end, best.term, original])
		i += n
	edits.reverse()
	var fixed := text
	for e in edits:
		fixed = fixed.substr(0, e[0]) + e[2] + fixed.substr(e[1])
	edits.reverse()
	out.text = fixed
	for e in edits:
		out.changes.append([e[3], e[2]])
	return out


static func _best_match(span: String, tokens: Array, i: int, n: int, cands: Array) -> Dictionary:
	var flat := _letters(span)
	if flat.length() < 3:
		return {}
	var lower := span.to_lower()
	var best := {}
	var best_score := 0.0
	for c in cands:
		if lower == c.lower:
			if COMMON.has(lower):
				continue                              # "the guide": an ordinary word, leave it alone
			return {"term": c.term, "score": 1.0}     # already right: only the casing is taken from the term
		if c.flat.length() < MIN_FUZZY_LEN or flat.length() < 4:
			continue
		var dist := _lev(flat, c.flat)
		var raw := 1.0 - float(dist) / float(maxi(flat.length(), c.flat.length()))
		if n != c.n:
			# a term heard as two words ("Lord vessel" for Lordvessel) or two terms' worth merged into one: only when
			# the letters agree almost exactly, so a neighbouring word ("in Terraria") is never swallowed
			var same_sound: bool = skeleton(span) == c.skel and str(c.skel).length() >= 4
			if not ((n == int(c.n) + 1 and (dist <= 1 or same_sound)) or (n == int(c.n) - 1 and raw >= 0.85)):
				continue
		var sk_a := skeleton(span)
		var sk_b: String = c.skel
		var sk := 1.0 - float(_lev(sk_a, sk_b)) / float(maxi(1, maxi(sk_a.length(), sk_b.length())))
		var ok := raw >= 0.8 or (sk_a == sk_b and sk_a.length() >= 2 and raw >= 0.45) or (sk >= 0.8 and sk_b.length() >= 5 and raw >= 0.6)
		if not ok:
			continue
		if _is_common_lowercase(span, tokens, i, n):
			continue
		var score := maxf(raw, sk * 0.95)
		if score > best_score:
			best_score = score
			best = {"term": c.term, "score": score}
	return best


## A lower-case run of ordinary English words is not a name. A capitalised word in the middle of a
## sentence (the recogniser's sign that it heard a name) is eligible.
static func _is_common_lowercase(span: String, tokens: Array, i: int, n: int) -> bool:
	var all_common := true
	for k in n:
		var w: String = tokens[i + k].word
		if not COMMON.has(w.to_lower()) and not _is_english_word(w):
			all_common = false
	if all_common and n >= 1:
		var first: String = tokens[i].word
		var capitalised := first != "" and first[0] == first[0].to_upper() and first[0] != first[0].to_lower()
		return not (capitalised and i > 0)
	return false


## Words a fuzzy match must not overwrite when written in lower case: a tiny list of everyday words that sit
## close to game terms (skeleton ~ Skeletron, cliff ~ Kliff, castle ~ Cassel ...).
static func _is_english_word(w: String) -> bool:
	return ["skeleton", "skeletons", "cliff", "cliffs", "castle", "planter", "golf", "queen", "kings", "smooth", "small", "smog", "orange", "beer", "creek", "dungeon", "cave", "temple", "forest", "island"].has(w.to_lower())


static func skeleton(text: String) -> String:
	var s := text.to_lower().replace("'s", "").replace("’s", "")
	var letters := ""
	for ch in s:
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			letters += ch
	s = letters
	for pair in [["ough", "o"], ["ght", "t"], ["ph", "f"], ["ck", "k"], ["qu", "kw"], ["kn", "n"], ["wr", "r"], ["gk", "k"], ["ch", "x"], ["sh", "x"]]:
		s = s.replace(pair[0], pair[1])
	var mapped := ""
	for ch in s:
		match ch:
			"c", "q", "g":
				mapped += "k"
			"z":
				mapped += "s"
			"v":
				mapped += "f"
			"d":
				mapped += "t"
			"b":
				mapped += "p"
			"a", "e", "i", "o", "u", "y", "h", "w":
				pass
			_:
				mapped += ch
	var out := ""
	for ch in mapped:
		if out == "" or out[-1] != ch:
			out += ch
	return out


static func _tokens(text: String) -> Array:
	var re := RegEx.new()
	re.compile("[A-Za-z0-9][A-Za-z0-9'’]*")
	var out := []
	for m in re.search_all(text):
		var word := m.get_string()
		var end := m.get_end()
		for suffix in ["'s", "\u2019s"]:
			if word.length() > 3 and word.ends_with(suffix):
				word = word.substr(0, word.length() - 2)
				end -= 2
				break
		out.append({"word": word, "start": m.get_start(), "end": end})
	return out


static func _span_text(text: String, tokens: Array, i: int, n: int) -> String:
	return text.substr(tokens[i].start, tokens[i + n - 1].end - tokens[i].start)


static func _words(term: String) -> Array:
	var out := []
	for w in str(term).replace(",", " ").split(" ", false):
		out.append(w)
	return out


static func _letters(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


static func _lev(a: String, b: String) -> int:
	var n := a.length()
	var m := b.length()
	if n == 0:
		return m
	if m == 0:
		return n
	var prev := PackedInt32Array()
	prev.resize(m + 1)
	for j in m + 1:
		prev[j] = j
	for i in range(1, n + 1):
		var cur := PackedInt32Array()
		cur.resize(m + 1)
		cur[0] = i
		for j in range(1, m + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
		prev = cur
	return prev[m]


## Word error rate (word-level edit distance / reference words), for the evaluation script and tests.
static func wer(reference: String, hypothesis: String) -> float:
	var r := _norm_words(reference)
	var h := _norm_words(hypothesis)
	if r.is_empty():
		return 0.0 if h.is_empty() else 1.0
	var prev := PackedInt32Array()
	prev.resize(h.size() + 1)
	for j in h.size() + 1:
		prev[j] = j
	for i in range(1, r.size() + 1):
		var cur := PackedInt32Array()
		cur.resize(h.size() + 1)
		cur[0] = i
		for j in range(1, h.size() + 1):
			var cost := 0 if r[i - 1] == h[j - 1] else 1
			cur[j] = mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
		prev = cur
	return float(prev[h.size()]) / float(r.size())


static func _norm_words(text: String) -> PackedStringArray:
	var s := ""
	for ch in text.to_lower():
		s += ch if ((ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == " ") else " "
	return PackedStringArray(s.split(" ", false))
