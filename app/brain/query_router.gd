class_name QueryRouter
extends RefCounted
## Rule-based, offline decisions made before any model is called:
##   classify()     command | smalltalk | factual   (only factual questions may use tools)
##   detect_game()  which game the player is asking about (any game, not just the loaded profile)
##   rewrite()      a conversational voice question -> a good wiki / web search query
## Everything is pure and static so it can be unit tested without a scene.

const FILLER_PREFIXES := [
	"hey filo", "hi filo", "okay filo", "ok filo", "filo",
	"can you please tell me", "could you please tell me", "can you tell me", "could you tell me", "would you tell me",
	"can you please", "could you please", "can you", "could you", "would you", "will you", "please",
	"i want to know", "i need to know", "i would like to know", "i'd like to know", "i was wondering", "i wonder",
	"do you know", "tell me", "let me know", "quick question", "so", "um", "uh", "and", "okay", "ok", "well", "hey",
]
const STOP_WORDS := [
	"a", "an", "the", "is", "are", "was", "were", "am", "be", "do", "does", "did", "i", "me", "my", "we", "you", "your",
	"to", "of", "in", "on", "at", "for", "with", "about", "from", "that", "this", "these", "those", "there", "here",
	"can", "could", "should", "would", "will", "just", "really", "actually", "kind", "sort", "like", "get", "got",
	"please", "tell", "know", "want", "need", "go", "going",
	"what", "whats", "what's", "how", "where", "who", "when", "why", "which", "any", "some",
]
const FOLLOWUP_CUES := [
	"what about", "how about", "and what", "and how", "and the", "what else", "tell me more", "more about", "more on",
	"the second", "the third", "the first", "the next", "the last", "second phase", "third phase", "next phase",
]
const PRONOUNS := ["it", "its", "it's", "that", "this", "them", "they", "their", "he", "she", "his", "her", "him", "there"]

const COMMANDS := {
	"stop": ["stop", "stop talking", "stop it", "be quiet", "quiet", "shut up", "cancel", "cancel that", "never mind", "nevermind", "enough", "that's enough", "thats enough", "hush"],
	"mute": ["mute", "mute yourself", "mute voice", "mute the voice", "go silent", "stay silent"],
	"unmute": ["unmute", "unmute yourself", "unmute voice", "speak again", "you can talk again"],
	"repeat": ["repeat", "repeat that", "say that again", "say again", "what was that", "come again"],
}

const SMALLTALK_PATTERNS := [
	"^(hi|hello|hey|yo|hiya|howdy|sup|good (morning|afternoon|evening|night))( there| filo)?$",
	"^(thanks|thank you|thanks a lot|thank you so much|cheers|ta|nice|great|cool|awesome|perfect|nice one|good job|well done|sweet|got it|i see|understood|makes sense|alright|all right|okay|ok|yes|yeah|no|nope|yep|lol|haha|wow|oh|ah|hmm|hm)( filo| thanks| thank you)?$",
	"^how are you( doing| today)?$",
	"^how('s| is) it going$",
	"^(who|what) are you$",
	"^what('s| is) your name$",
	"^what can you do$",
	"^what do you do$",
	"^(are you|you) (there|listening|awake|alive|working)$",
	"^can you hear me$",
	"^(test|testing|testing one two|check|mic check)$",
	"^(good ?bye|see you|see you later|later|good night|night night)$",
	"^i('m| am) (back|ready|here)$",
	"^tell me (a )?(joke|something funny)$",
]


## The lowercase, punctuation-free form used for matching (apostrophes kept).
static func normalize(text: String) -> String:
	var t := text.to_lower()
	var re := RegEx.new()
	re.compile("[^a-z0-9' ]+")
	t = re.sub(t, " ", true)
	var ws := RegEx.new()
	ws.compile("\\s+")
	return ws.sub(t, " ", true).strip_edges()


static func _strip_fillers(norm: String) -> String:
	var t := norm
	var changed := true
	while changed:
		changed = false
		for f in FILLER_PREFIXES:
			if t == f:
				return ""
			if t.begins_with(f + " "):
				t = t.substr(f.length() + 1).strip_edges()
				changed = true
				break
	return t


## "command" | "smalltalk" | "factual" | "empty". Only "factual" may reach the tool loop.
static func classify(text: String) -> String:
	var norm := normalize(text)
	if norm == "":
		return "empty"
	var core := _strip_fillers(norm)
	for c in [norm, core]:
		if c == "":
			continue
		if command_of(c) != "":
			return "command"
	if core == "":
		return "smalltalk"
	var words := core.split(" ", false)
	if words.size() <= 8:
		for p in SMALLTALK_PATTERNS:
			var re := RegEx.new()
			re.compile(p)
			if re.search(core) != null or re.search(norm) != null:
				return "smalltalk"
	return "factual"


## The command in a raw utterance (fillers such as "hey filo" ignored), or "".
static func command_for(text: String) -> String:
	var norm := normalize(text)
	for c in [norm, _strip_fillers(norm)]:
		if c != "":
			var cmd := command_of(c)
			if cmd != "":
				return cmd
	return ""


## The command word for a short utterance ("stop", "mute", "unmute", "repeat"), or "".
static func command_of(norm: String) -> String:
	var t := norm.replace(" please", "").replace(" filo", "").strip_edges()
	if t.split(" ", false).size() > 5:
		return ""
	for cmd in COMMANDS:
		if t in COMMANDS[cmd]:
			return cmd
	return ""


# ----------------------------------------------------------------------- games

## games: [{name, aliases}] -> {name, source} where source is "known", "pattern" or "" (nothing found).
## A known alias always wins (longest first); otherwise a capitalised phrase after in/on/for/from
## at the end of the question is taken as the game name ("...Eye of Cthulhu in Terraria").
static func detect_game(question: String, games: Array) -> Dictionary:
	var padded := " " + normalize(question) + " "
	var best := ""
	var best_len := 0
	for g in games:
		if typeof(g) != TYPE_DICTIONARY:
			continue
		var aliases: Array = [str(g.get("name", ""))]
		aliases.append_array(g.get("aliases", []))
		for a in aliases:
			var an := normalize(str(a))
			if an != "" and padded.contains(" " + an + " ") and an.length() > best_len:
				best = str(g.get("name", ""))
				best_len = an.length()
	if best != "":
		return {"name": best, "source": "known"}
	var re := RegEx.new()
	re.compile("(?:\\b(?:in|on|for|from|of)\\s+(?:the\\s+)?(?:game\\s+)?)([A-Z0-9][\\w:'\\-]*(?:\\s+(?:[A-Z0-9][\\w:'\\-]*|of|the|and|II|III|IV|VI|VII|VIII|IX|X))*)\\s*[?.!]*$")
	var m := re.search(question.strip_edges())
	if m != null:
		var cand := m.get_string(1).strip_edges()
		var low := cand.to_lower()
		if not (low in ["it", "the game", "game", "this game", "general", "order", "time", "case", "fact", "life", "general"]):
			return {"name": cand, "source": "pattern"}
	return {"name": "", "source": ""}


## True when two game names refer to the same game (alias tables optional).
static func same_game(a: String, b: String, games: Array = []) -> bool:
	var na := normalize(a)
	var nb := normalize(b)
	if na == "" or nb == "":
		return true
	if na == nb or na.contains(nb) or nb.contains(na):
		return true
	for g in games:
		if typeof(g) != TYPE_DICTIONARY:
			continue
		var names := PackedStringArray([normalize(str(g.get("name", "")))])
		for al in g.get("aliases", []):
			names.append(normalize(str(al)))
		var ha := false
		var hb := false
		for n in names:
			if n == "":
				continue
			if na.contains(n) or n.contains(na):
				ha = true
			if nb.contains(n) or n.contains(nb):
				hb = true
		if ha and hb:
			return true
	return false


# --------------------------------------------------------------------- rewriting

## {wiki, web, topic, followup}. `topic` is what the question is about (for the session memory);
## `session_topic` is the topic of the previous turn, used to resolve "what about the second phase".
static func rewrite(question: String, game: String, session_topic: String = "") -> Dictionary:
	var original := question.strip_edges()
	var norm := _strip_fillers(normalize(original))
	var game_norm := normalize(game)
	# the game name and a trailing "in <game>" carry no information for the wiki search
	if game_norm != "":
		norm = norm.replace(" in " + game_norm, "").replace(" on " + game_norm, "").replace(" for " + game_norm, "").replace(game_norm, "").strip_edges()
	var entity := _entity_phrase(original, game)
	var followup := false
	for cue in FOLLOWUP_CUES:
		if norm.begins_with(cue) or norm.contains(" " + cue + " "):
			followup = true
	var words := norm.split(" ", false)
	if entity == "" and session_topic != "":
		for w in words:
			if w in PRONOUNS:
				followup = true
	var keywords := PackedStringArray()
	for w in words:
		if not (w in STOP_WORDS):
			keywords.append(w)
	var kw := " ".join(keywords).strip_edges()
	var topic := entity
	if entity == "" and followup and session_topic != "":
		topic = session_topic
	elif entity == "":
		topic = kw
	var wiki := entity if entity != "" else kw
	if followup and session_topic != "" and entity == "":
		wiki = (session_topic + " " + kw).strip_edges()
	wiki = wiki.replace("'s", "").replace("\u2019s", "")       # "Oongka's role" searches the wiki for "Oongka"
	topic = topic.replace("'s", "").replace("\u2019s", "")
	var web := ("%s %s" % [game, wiki if wiki != "" else kw]).strip_edges()
	if wiki == "":
		wiki = norm
	return {"wiki": wiki, "web": web, "topic": topic, "followup": followup and session_topic != ""}


## The longest run of capitalised words that is not at the start of the sentence and not the game
## name itself ("Eye of Cthulhu", "Lady Butterfly", "Shinobi Firecracker").
static func _entity_phrase(question: String, game: String) -> String:
	var re := RegEx.new()
	re.compile("[A-Z0-9][\\w'\\-]*(?:\\s+(?:of|the|and|de|du|von|[A-Z0-9][\\w'\\-]*))*")
	var best := ""
	var game_low := game.to_lower()
	for m in re.search_all(question):
		if m.get_start() == 0 or question.substr(0, m.get_start()).strip_edges() == "":
			# sentence-initial capital ("How", "Where"): only keep when it continues into more capitalised words
			var first := m.get_string().split(" ")[0]
			if first.to_lower() in ["how", "where", "what", "who", "when", "why", "which", "can", "could", "is", "are", "do", "does", "tell", "hey", "okay", "ok", "so", "i"]:
				continue
		var s := m.get_string().strip_edges()
		var trail := RegEx.new()
		trail.compile("(?:\\s+(?:of|the|and|de|du|von))+$")
		s = trail.sub(s, "", true).strip_edges()
		var sl := s.to_lower()
		if game_low != "" and (sl == game_low or game_low.contains(sl) or sl.contains(game_low)):
			continue
		if sl in ["i", "i'm", "i'd", "i'll", "filo", "hey filo"]:
			continue
		if s.length() > best.length():
			best = s
	return best
