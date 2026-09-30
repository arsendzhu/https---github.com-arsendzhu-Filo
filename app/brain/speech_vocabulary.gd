class_name SpeechVocabulary
extends RefCounted
## Per-game words that speech recognisers get wrong (boss and item names, places, the game's own title).
## They are sent to the helper (`set_vocab`), which hands them to every recognition request as hints
## (contextualStrings), and TermCorrector uses them to repair what was misheard anyway.
##
## Sources, in priority order: the game's profile (`vocabulary` in profile.json + its note titles),
## profiles/vocabulary.json (one entry per game; adding a game is one line), and `speech.hotwords`
## in config.json ({"game name": ["term", ...]} or a plain list that applies to every game).

const MAX_TERMS := 100


## {"Game Name": [terms]} from profiles/vocabulary.json (the "_comment" key is ignored).
static func load_table(profiles_dir: String) -> Dictionary:
	var out := {}
	var path := profiles_dir.path_join("vocabulary.json")
	if not FileAccess.file_exists(path):
		return out
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	for k in parsed:
		if not str(k).begins_with("_") and typeof(parsed[k]) == TYPE_ARRAY:
			out[str(k)] = parsed[k]
	return out


## The hint words for `game` (current game first, then the other games' titles), at most MAX_TERMS.
static func for_game(table: Dictionary, game: String, profile: GameProfile = null, config_hotwords = null) -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {}
	var add := func(term) -> void:
		var t := str(term).strip_edges()
		if t != "" and not seen.has(t.to_lower()) and out.size() < MAX_TERMS:
			seen[t.to_lower()] = true
			out.append(t)
	if profile != null:
		for t in profile.vocabulary:
			add.call(t)
		for n in profile.notes:
			add.call(str(n.get("title", "")))
	for k in table:
		if QueryRouter.same_game(str(k), game):
			for t in table[k]:
				add.call(t)
	if typeof(config_hotwords) == TYPE_DICTIONARY:
		for k in config_hotwords:
			if QueryRouter.same_game(str(k), game):
				for t in config_hotwords[k]:
					add.call(t)
	elif typeof(config_hotwords) == TYPE_ARRAY:
		for t in config_hotwords:
			add.call(t)
	# the other games: just their names, so "in Terraria" is recognised while another game is loaded
	for k in table:
		if not QueryRouter.same_game(str(k), game):
			add.call(str(k))
	return out
