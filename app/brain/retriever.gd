class_name Retriever
extends RefCounted
## Small offline BM25 retriever over the profile's note chunks, plus a
## confidence score that decides whether to fall back to a live web search.
##
## confidence = max(idf-weighted share of the question's terms found in the top
## chunk, share of the top chunk's title terms present in the question).
## Questions full of words the notes never mention score low -> web fallback.

const K1 := 1.5
const B := 0.75
const TARGET_CHUNK_WORDS := 90
const MAX_CHUNK_WORDS := 200

## Generic question words that carry no retrieval signal.
const STOPWORDS := [
	"a", "an", "the", "and", "or", "but", "if", "then", "so", "of", "to", "in", "on", "at", "by",
	"for", "with", "from", "into", "about", "as", "is", "are", "was", "were", "be", "been", "being",
	"am", "do", "does", "did", "doing", "have", "has", "had", "i", "im", "me", "my", "we", "our",
	"you", "your", "he", "she", "it", "its", "they", "them", "this", "that", "these", "those",
	"what", "whats", "which", "who", "whom", "how", "why", "when", "where", "can", "could",
	"should", "would", "will", "shall", "may", "might", "must", "not", "no", "yes", "there",
	"here", "any", "some", "all", "just", "also", "very", "really", "get", "got", "need",
	"want", "help", "please", "tell", "know", "stuck", "missing", "beat", "kill", "defeat",
	"fight", "fighting", "tips", "tip", "hard", "best", "way", "again", "keep", "keeps",
	"always", "much", "many", "lot", "thing", "things", "something", "anything", "up", "down",
	"out", "off", "over", "still", "too", "only", "own", "same", "than", "let", "lets", "like",
	"vs", "versus", "ok", "okay", "um", "uh", "hey", "hi", "hello", "filo", "against", "am",
	"dying", "die", "keep", "cant", "can't", "dont", "don't", "wont", "won't", "hes", "shes",
	"isnt", "isn't", "one", "guy", "him", "her", "his", "their", "does", "deal", "handle",
]

var chunks: Array = []      # {title, source, text, tf: Dictionary, len: int, title_terms: PackedStringArray}
var df: Dictionary = {}
var avgdl := 1.0
var _regex := RegEx.new()
var _stop := {}


func _init() -> void:
	_regex.compile("[^a-z0-9']+")
	for w in STOPWORDS:
		_stop[w] = true


func tokenize(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cleaned := _regex.sub(text.to_lower(), " ", true)
	for raw in cleaned.split(" ", false):
		if _stop.has(raw):
			continue
		var w: String = raw.replace("'", "")
		if w.length() < 2 or _stop.has(w):
			continue
		var s := stem(w)
		if _stop.has(s):
			continue
		out.append(s)
	return out


static func stem(w: String) -> String:
	if w.length() > 5 and w.ends_with("ing"):
		return w.substr(0, w.length() - 3)
	if w.length() > 4 and w.ends_with("ies"):
		return w.substr(0, w.length() - 3) + "y"
	if w.length() > 4 and w.ends_with("ed"):
		return w.substr(0, w.length() - 2)
	if w.length() > 4 and w.ends_with("es") and not w.ends_with("ses"):
		return w.substr(0, w.length() - 2)
	if w.length() > 3 and w.ends_with("s") and not w.ends_with("ss"):
		return w.substr(0, w.length() - 1)
	return w


func build(profile: GameProfile) -> void:
	chunks.clear()
	df.clear()
	for note in profile.notes:
		var title_terms := tokenize(note.title)
		for piece in split_chunks(note.body):
			var terms := tokenize(piece)
			var tf := {}
			for t in terms:
				tf[t] = tf.get(t, 0) + 1
			for t in title_terms:
				tf[t] = tf.get(t, 0) + 2   # title terms count extra
			chunks.append({
				"title": note.title,
				"source": note.source,
				"text": piece,
				"tf": tf,
				"len": terms.size() + title_terms.size() * 2,
				"title_terms": title_terms,
			})
			for t in tf:
				df[t] = df.get(t, 0) + 1
	var total := 0
	for c in chunks:
		total += c.len
	avgdl = float(total) / maxf(chunks.size(), 1.0)


static func split_chunks(body: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var current_words := 0
	for para in body.split("\n\n", false):
		var p := para.strip_edges()
		if p == "":
			continue
		var words := p.split(" ", false).size()
		if current != "" and current_words + words > TARGET_CHUNK_WORDS:
			out.append(current)
			current = ""
			current_words = 0
		current = p if current == "" else current + "\n\n" + p
		current_words += words
		if current_words >= MAX_CHUNK_WORDS:
			out.append(current)
			current = ""
			current_words = 0
	if current != "":
		out.append(current)
	return out


func idf(term: String) -> float:
	var n := chunks.size()
	var d: int = df.get(term, 0)
	return log(1.0 + (n - d + 0.5) / (d + 0.5))


func search(query: String, k: int = 4) -> Dictionary:
	var unique := {}
	for t in tokenize(query):
		unique[t] = true
	var q_terms := unique.keys()
	var scored := []
	for c in chunks:
		var s := 0.0
		for t in q_terms:
			var tf: int = c.tf.get(t, 0)
			if tf == 0:
				continue
			s += idf(t) * (tf * (K1 + 1.0)) / (tf + K1 * (1.0 - B + B * c.len / avgdl))
		if s > 0.0:
			scored.append({"chunk": c, "score": s})
	scored.sort_custom(func(a, b): return a.score > b.score)
	var results := scored.slice(0, mini(k, scored.size()))
	var confidence := 0.0
	if results.size() > 0 and q_terms.size() > 0:
		var top: Dictionary = results[0].chunk
		var matched := 0.0
		var total := 0.0
		for t in q_terms:
			var w := idf(t)
			total += w
			if top.tf.has(t):
				matched += w
		var coverage := matched / total if total > 0.0 else 0.0
		var title_cov := 0.0
		if top.title_terms.size() > 0:
			var hit := 0
			for t in top.title_terms:
				if unique.has(t):
					hit += 1
			title_cov = float(hit) / top.title_terms.size()
		confidence = maxf(coverage, title_cov)
	return {"results": results, "confidence": confidence, "terms": q_terms}
