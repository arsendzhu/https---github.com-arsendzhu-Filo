extends SceneTree
## Dev tool: measures TermCorrector on the recogniser transcripts recorded by scripts/eval_stt.py.
##   stt/venv/bin/python scripts/eval_stt.py --models base.en --dump-hyps logs/stt_hyps_base.json
##   godot --headless --path app -s tests/term_correction_eval.gd -- logs/stt_hyps_base.json
## Reports WER and key-word recall before/after, how many transcripts were changed, and how many of
## the changes were regressions (a transcript that was closer to the reference before).


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var path := FiloConfig.project_root().path_join(args[0] if args.size() > 0 else "logs/stt_hyps_base.json")
	var hyps = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(hyps) != TYPE_ARRAY:
		print("cannot read " + path)
		quit(1)
		return
	var table := SpeechVocabulary.load_table(FiloConfig.project_root().path_join("profiles"))
	var n := 0
	var wer_before := 0.0
	var wer_after := 0.0
	var rec_before := 0.0
	var rec_after := 0.0
	var changed := 0
	var improved := 0
	var regressed := 0
	var by_scenario := {}
	for h in hyps:
		var terms := SpeechVocabulary.for_game(table, str(h.game))
		var text := str(h.new)
		var fixed := TermCorrector.correct(text, terms)
		var wb := TermCorrector.wer(str(h.ref), text)
		var wa := TermCorrector.wer(str(h.ref), fixed.text)
		var rb := _recall(text, h.keywords)
		var ra := _recall(fixed.text, h.keywords)
		n += 1
		wer_before += wb
		wer_after += wa
		rec_before += rb
		rec_after += ra
		if fixed.text != text:
			changed += 1
			if wa < wb or ra > rb:
				improved += 1
			if wa > wb or ra < rb:
				regressed += 1
				print("  REGRESSION: '%s' -> '%s' (ref '%s')" % [text, fixed.text, h.ref])
		var sc := str(h.scenario)
		if not by_scenario.has(sc):
			by_scenario[sc] = {"n": 0, "wb": 0.0, "wa": 0.0}
		by_scenario[sc].n += 1
		by_scenario[sc].wb += wb
		by_scenario[sc].wa += wa
	print("transcripts: %d, changed by the corrector: %d (improved %d, regressed %d)" % [n, changed, improved, regressed])
	print("mean WER      before %.3f  after %.3f" % [wer_before / n, wer_after / n])
	print("keyword recall before %.3f  after %.3f" % [rec_before / n, rec_after / n])
	for k in by_scenario:
		print("  %-32s WER %.3f -> %.3f" % [k, by_scenario[k].wb / by_scenario[k].n, by_scenario[k].wa / by_scenario[k].n])
	quit(1 if regressed > 0 else 0)


func _recall(text: String, keywords: Array) -> float:
	var words := TermCorrector._norm_words(text)
	var flat := "".join(words)
	var hit := 0
	for k in keywords:
		if words.has(str(k)) or flat.contains(str(k)):
			hit += 1
	return float(hit) / float(keywords.size())
