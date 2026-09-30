class_name FiloConfig
extends RefCounted
## Configuration: defaults, deep-merged with <repo>/config.json, then <repo>/.env
## and environment variables (ANTHROPIC_API_KEY, NVIDIA_API_KEY, FILO_MODEL,
## FILO_PROVIDER, FILO_NIM_MODEL) and finally command-line overrides.

const DEFAULTS := {
	"anthropic_api_key": "",
	"nvidia_api_key": "",
	"llm": {"provider": "auto"},
	"api_base_url": "https://api.anthropic.com",
	"model": "claude-opus-5",
	"effort": "low",
	"max_tokens": 700,
	"refusal_fallbacks": true,
	"nim": {"base_url": "https://integrate.api.nvidia.com/v1", "model": "nvidia/nemotron-3-super-120b-a12b", "max_tokens": 500, "temperature": 0.4, "reasoning": false},
	"research": {
		"enabled": true,
		"models": [
			{"id": "deepseek-ai/deepseek-v4.1-flash", "extra_body_no_think": {"chat_template_kwargs": {"thinking": false}}},
			{"id": "nvidia/nemotron-3-super-120b-a12b", "extra_body_no_think": {"chat_template_kwargs": {"enable_thinking": false}}},
		],
		"thinking": false,
		"max_rounds": 4,
		"max_tool_calls": 6,
		"max_page_chars": 6000,
		"max_tokens": 350,
		"temperature": 0.3,
		"attempt_timeout": 20.0,
		"tool_timeout": 10.0,
		"cache_ttl": 900.0,
		"breaker_seconds": 300.0,
		"warmup_probe": true,
		"claude_fallback": true,
		"search_provider": "duckduckgo",
		"max_redirects": 3,
		"max_fetch_bytes": 1500000,
		"force_first_tool": "required",
		# One line per game is enough: "game name": "https://wiki-host" (api.php is assumed). Use the long
		# form {"base_url", "api_path", "name", "aliases"} for wikis whose API lives elsewhere. Games
		# that are not listed are discovered at question time: web_search -> a wiki that answers api.php.
		"wikis": {
			"terraria": "https://terraria.wiki.gg",
			"minecraft": "https://minecraft.wiki",
			"stardew valley": {"aliases": ["stardew valley", "stardew"], "base_url": "https://stardewvalleywiki.com", "api_path": "/mediawiki/api.php", "name": "Stardew Valley wiki"},
			"dark souls": {"aliases": ["dark souls", "darksouls"], "base_url": "https://darksouls.fandom.com", "api_path": "/api.php", "name": "Dark Souls wiki"},
			"dark souls 2": {"aliases": ["dark souls 2", "dark souls ii", "darksouls2"], "base_url": "https://darksouls2.fandom.com", "api_path": "/api.php", "name": "Dark Souls 2 wiki"},
			"dark souls 3": {"aliases": ["dark souls 3", "dark souls iii", "darksouls3"], "base_url": "https://darksouls3.fandom.com", "api_path": "/api.php", "name": "Dark Souls 3 wiki"},
			"crimson desert": {"aliases": ["crimson desert"], "base_url": "https://crimsondesert.fandom.com", "api_path": "/api.php", "name": "Crimson Desert wiki"},
		},
	},
	"wake_word": {"enabled": true, "phrase": "hey filo", "bye_phrase": "bye filo", "silence_ms": 1500},
	"web_search": {
		"enabled": true,
		"max_uses": 2,
		"confidence_threshold": 0.45,
		"provider": "auto",
		"wikipedia": {"enabled": true, "language": "en", "max_pages": 2, "user_agent": "Filo/0.1 (game overlay companion; local use)", "base_url": ""},
	},
	"default_profile": "sekiro",
	"profiles_dir": "profiles",
	"hotkey": {"key": "space", "modifiers": ["option"]},
	"helper": {
		"enabled": true,
		"path": "helper/build/Filo Helper.app",
		"args": "",
		"port": 47821,
		"allow_server_speech": false,
		"locale": "en-US",
	},
	"tts": {
		"enabled": true,
		"provider": "auto",
		"voice": "Ava, Zoe, Samantha",
		"rate": 1.0,
		"pitch": 1.0,
		"volume": 70,
		"kokoro": {"voice": "af_heart", "speed": 1.05, "port": 47823},
	},
	"overlay": {"corner": "bottom_right", "margin": 24, "width": 620, "height": 420},
	"mascot": {"internal_resolution": 96, "size": 200, "dither": 0.09, "vertex_jitter": 0.0},
	"behavior": {
		"idle_timeout": 0.0,
		"answer_linger": 0.0,
		"greet_on_launch": true,
		"greet_linger": 8.0,
		"reprompt": true,
		"followup_listen_seconds": 30,
		"conversation_turns": 4,
		"reprompt_phrases": ["Anything else?", "Want to know more?", "What else can I help with?", "Need anything else?", "Ask me more if you like."],
		"farewell_phrases": ["Bye!", "See you!", "Good luck out there!", "Later!"],
	},
	"screen_reading": {"enabled": false},
	"session": {"idle_reset_seconds": 900},
	"verbose": false,
}

var data: Dictionary = {}
var source_path := ""
var dotenv_path := ""


static func project_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


static func load_default(args: Dictionary = {}) -> FiloConfig:
	var cfg := FiloConfig.new()
	cfg.data = DEFAULTS.duplicate(true)
	var path: String = str(args["config"]) if args.has("config") else project_root().path_join("config.json")
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			merge_into(cfg.data, parsed)
			cfg.source_path = path
		else:
			FiloLog.warn("Could not parse %s — using defaults" % path)
	var dotenv := {}
	var dotenv_file := project_root().path_join(".env")
	if FileAccess.file_exists(dotenv_file):
		dotenv = parse_dotenv(FileAccess.get_file_as_string(dotenv_file))
		cfg.dotenv_path = dotenv_file
	var env_key := env_or_dotenv(dotenv, "ANTHROPIC_API_KEY")
	if env_key != "":
		cfg.data["anthropic_api_key"] = env_key
	var nv_key := env_or_dotenv(dotenv, "NVIDIA_API_KEY")
	if nv_key == "":
		nv_key = env_or_dotenv(dotenv, "NIM_API_KEY")
	if nv_key != "":
		cfg.data["nvidia_api_key"] = nv_key
	var env_model := env_or_dotenv(dotenv, "FILO_MODEL")
	if env_model != "":
		cfg.data["model"] = env_model
	var env_provider := env_or_dotenv(dotenv, "FILO_PROVIDER")
	if env_provider != "":
		cfg.data["llm"]["provider"] = env_provider
	var env_nim_model := env_or_dotenv(dotenv, "FILO_NIM_MODEL")
	if env_nim_model != "":
		cfg.data["nim"]["model"] = env_nim_model
	cfg.apply_args(args)
	cfg.normalize_keys()
	return cfg


## KEY=value lines; quotes stripped; "#" comments ignored; `export` allowed.
static func parse_dotenv(text: String) -> Dictionary:
	var out := {}
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if line.begins_with("export "):
			line = line.substr(7).strip_edges()
		var eq := line.find("=")
		if eq <= 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if value.length() >= 2 and ((value.begins_with("\"") and value.ends_with("\"")) or (value.begins_with("'") and value.ends_with("'"))):
			value = value.substr(1, value.length() - 2)
		else:
			var hash := value.find(" #")
			if hash >= 0:
				value = value.substr(0, hash).strip_edges()
		out[key] = value
	return out


static func env_or_dotenv(dotenv: Dictionary, key: String) -> String:
	var v := OS.get_environment(key)
	if v != "":
		return v
	return str(dotenv.get(key, ""))


## Drops placeholders ("sk-ant-...") and moves an NVIDIA key that was pasted
## into ANTHROPIC_API_KEY (nvapi-…) over to nvidia_api_key.
func normalize_keys() -> void:
	var a := str(data.get("anthropic_api_key", "")).strip_edges()
	if a.begins_with("nvapi-"):
		FiloLog.warn("ANTHROPIC_API_KEY holds an NVIDIA key (nvapi-…) — using it as the NVIDIA NIM key instead")
		if str(data.get("nvidia_api_key", "")).strip_edges() == "":
			data["nvidia_api_key"] = a
		a = ""
	if a.ends_with("...") or a.begins_with("<") or a.contains("your-"):
		a = ""
	data["anthropic_api_key"] = a
	var n := str(data.get("nvidia_api_key", "")).strip_edges()
	if n.ends_with("...") or n.begins_with("<") or n.contains("your-"):
		n = ""
	data["nvidia_api_key"] = n


## "anthropic", "nim" or "none" (no usable key for the chosen provider).
func provider() -> String:
	var p := str(get_value("llm.provider", "auto")).to_lower().strip_edges()
	var has_a := str(data.get("anthropic_api_key", "")) != ""
	var has_n := str(data.get("nvidia_api_key", "")) != ""
	match p:
		"auto":
			if has_a:
				return "anthropic"
			if has_n:
				return "nim"
			return "none"
		"anthropic", "claude":
			return "anthropic" if has_a else "none"
		"nim", "nvidia":
			return "nim" if has_n else "none"
		_:
			return "none"


func apply_args(args: Dictionary) -> void:
	if args.has("profile"):
		data["default_profile"] = str(args["profile"])
	if args.has("api_base"):
		data["api_base_url"] = str(args["api_base"])
	if args.has("port"):
		data["helper"]["port"] = int(str(args["port"]))
	if args.has("helper_cmd"):
		data["helper"]["path"] = str(args["helper_cmd"])
	if args.has("helper_args"):
		data["helper"]["args"] = str(args["helper_args"])
	if args.has("no_helper"):
		data["helper"]["enabled"] = false
	if args.has("mute"):
		data["tts"]["enabled"] = false
	if args.has("no_greet"):
		data["behavior"]["greet_on_launch"] = false
	if args.has("verbose"):
		data["verbose"] = true
	if args.has("provider"):
		data["llm"]["provider"] = str(args["provider"])
	if args.has("nim_base"):
		data["nim"]["base_url"] = str(args["nim_base"])
	if args.has("wiki_base"):
		data["web_search"]["wikipedia"]["base_url"] = str(args["wiki_base"])
	if args.has("tts_provider"):
		data["tts"]["provider"] = str(args["tts_provider"])
	if args.has("no_reprompt"):
		data["behavior"]["reprompt"] = false


## Dotted lookup, e.g. get_value("web_search.enabled", true).
func get_value(path: String, default = null):
	var node = data
	for part in path.split("."):
		if typeof(node) == TYPE_DICTIONARY and node.has(part):
			node = node[part]
		else:
			return default
	return node


## Resolves a path from config: absolute paths are kept, relative paths are
## relative to the repository root (the folder that contains app/).
func resolve_path(p: String) -> String:
	if p.is_absolute_path():
		return p
	return FiloConfig.project_root().path_join(p).simplify_path()


func hotkey_label() -> String:
	var mods: Array = get_value("hotkey.modifiers", [])
	var symbols := {"command": "⌘", "cmd": "⌘", "option": "⌥", "alt": "⌥", "control": "⌃", "ctrl": "⌃", "shift": "⇧"}
	var out := ""
	for m in mods:
		out += symbols.get(str(m).to_lower(), str(m))
	var key := str(get_value("hotkey.key", "space"))
	return out + (" " if out != "" else "") + key.capitalize()


static func merge_into(base: Dictionary, over: Dictionary) -> void:
	for k in over:
		if typeof(base.get(k)) == TYPE_DICTIONARY and typeof(over[k]) == TYPE_DICTIONARY:
			merge_into(base[k], over[k])
		else:
			base[k] = over[k]
