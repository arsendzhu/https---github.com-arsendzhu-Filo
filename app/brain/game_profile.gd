class_name GameProfile
extends RefCounted
## A game profile: everything game-specific lives here (profiles/<id>/), nothing
## game-specific lives in the core app. Phase 0 uses: name, detection hints,
## persona hint and the curated notes that feed retrieval.
##
## Note format (profiles/<id>/notes/*.md):
##   # Title
##   source: https://where-you-learned-it
##   tags: comma, separated
##
##   Body paragraphs in your own words...

var id := ""
var name := ""
var dir := ""
var process_names := PackedStringArray()
var window_titles := PackedStringArray()
var persona_hint := ""
var vocabulary := PackedStringArray()   # extra words speech recognisers should expect (boss/item names)
var wiki: Dictionary = {}   # {base_url, api_path, name} of this game's MediaWiki/Fandom site (research tools)
var notes: Array = []   # Array[Dictionary] {title, source, tags, body, file}
var load_error := ""


static func list_profiles(profiles_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(profiles_dir)
	if da == null:
		return out
	da.list_dir_begin()
	var n := da.get_next()
	while n != "":
		if da.current_is_dir() and not n.begins_with(".") and FileAccess.file_exists(profiles_dir.path_join(n).path_join("profile.json")):
			out.append(n)
		n = da.get_next()
	da.list_dir_end()
	out.sort()
	return out


static func load_from(profiles_dir: String, profile_id: String) -> GameProfile:
	var p := GameProfile.new()
	p.id = profile_id
	p.dir = profiles_dir.path_join(profile_id)
	var pj := p.dir.path_join("profile.json")
	if not FileAccess.file_exists(pj):
		p.load_error = "profile.json not found at " + pj
		p.name = profile_id
		return p
	var data = JSON.parse_string(FileAccess.get_file_as_string(pj))
	if typeof(data) != TYPE_DICTIONARY:
		p.load_error = "profile.json is not valid JSON: " + pj
		p.name = profile_id
		return p
	p.name = str(data.get("name", profile_id))
	var detect: Dictionary = data.get("detect", {})
	for s in detect.get("process_names", []):
		p.process_names.append(str(s))
	for s in detect.get("window_titles", []):
		p.window_titles.append(str(s))
	p.persona_hint = str(data.get("persona_hint", ""))
	if typeof(data.get("wiki")) == TYPE_DICTIONARY:
		p.wiki = data["wiki"]
	if typeof(data.get("vocabulary")) == TYPE_ARRAY:
		for w in data["vocabulary"]:
			p.vocabulary.append(str(w))
	var kb: Dictionary = data.get("kb", {})
	p._load_notes(p.dir.path_join(str(kb.get("notes_dir", "notes"))))
	return p


func _load_notes(notes_dir: String) -> void:
	var da := DirAccess.open(notes_dir)
	if da == null:
		return
	var files := PackedStringArray()
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname.get_extension().to_lower() == "md":
			files.append(fname)
		fname = da.get_next()
	da.list_dir_end()
	files.sort()
	for f in files:
		var note := parse_note(FileAccess.get_file_as_string(notes_dir.path_join(f)), f)
		if note.body != "":
			notes.append(note)


## Returns true when a running app name (or window title) matches this profile.
func matches_app(app_name: String) -> bool:
	var lower := app_name.to_lower()
	if lower == "":
		return false
	for pn in process_names:
		var p := str(pn).to_lower().trim_suffix(".exe")
		if p != "" and (lower == p or lower.contains(p)):
			return true
	for wt in window_titles:
		var t := str(wt).to_lower()
		if t != "" and lower.contains(t):
			return true
	return false


static func parse_note(text: String, file: String) -> Dictionary:
	var note := {"title": "", "source": "", "tags": "", "body": "", "file": file}
	var lines := text.split("\n")
	var idx := 0
	while idx < lines.size() and lines[idx].strip_edges() == "":
		idx += 1
	if idx < lines.size() and lines[idx].strip_edges().begins_with("# "):
		note["title"] = lines[idx].strip_edges().substr(2).strip_edges()
		idx += 1
	else:
		note["title"] = file.get_basename().replace("_", " ").replace("-", " ").capitalize()
	# "key: value" metadata lines until the first blank line
	while idx < lines.size():
		var line := lines[idx].strip_edges()
		if line == "":
			idx += 1
			break
		var colon := line.find(":")
		if colon > 0:
			var key := line.substr(0, colon).strip_edges().to_lower()
			if key.length() <= 16 and not key.contains(" "):
				note[key] = line.substr(colon + 1).strip_edges()
				idx += 1
				continue
		break
	note["body"] = "\n".join(lines.slice(idx)).strip_edges()
	return note
