extends SceneTree
## Prints the non-secret configuration facts scripts/doctor.py needs, as one JSON line. No key is ever printed
## (only whether one exists) and nothing is sent anywhere.


func _init() -> void:
	var cfg := FiloConfig.load_default({})
	var models := []
	for m in cfg.get_value("research.models", []):
		models.append(str(m.get("id", m)) if typeof(m) == TYPE_DICTIONARY else str(m))
	var wikis := {}
	var table := ResearchAgent.normalize_wikis(cfg.get_value("research.wikis", {}))
	for k in table:
		wikis[k] = table[k].base_url + table[k].api_path
	var out := {
		"nim_base": str(cfg.get_value("nim.base_url", "")),
		"nim_model": str(cfg.get_value("nim.model", "")),
		"research_models": models,
		"wikis": wikis,
		"helper_port": int(cfg.get_value("helper.port", 47821)),
		"kokoro_port": int(cfg.get_value("tts.kokoro.port", 47823)),
		"hotkey": cfg.hotkey_label(),
		"has_nvidia_key": str(cfg.get_value("nvidia_api_key", "")) != "",
		"has_anthropic_key": str(cfg.get_value("anthropic_api_key", "")) != "",
		"provider": cfg.provider(),
		"settings_path": cfg.resolve_path("settings.json"),
	}
	print("DOCTOR_PROBE " + JSON.stringify(out))
	quit()
