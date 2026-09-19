class_name WikipediaClient
extends Node
## Free web fallback: searches English Wikipedia (MediaWiki search API) and
## fetches page summaries (REST summary API). No API key; Wikipedia asks for a
## descriptive User-Agent, which is sent on every request.
## Results have the same shape as knowledge-base chunks so the pipeline can
## append them as extra numbered passages.

var base_url := "https://en.wikipedia.org"
var language := "en"
var max_pages := 2
var user_agent := "Filo/0.1 (game overlay companion; local use)"
var timeout_sec := 10.0


func configure(cfg: FiloConfig) -> void:
	language = str(cfg.get_value("web_search.wikipedia.language", "en"))
	max_pages = maxi(1, int(cfg.get_value("web_search.wikipedia.max_pages", 2)))
	user_agent = str(cfg.get_value("web_search.wikipedia.user_agent", user_agent))
	var override := str(cfg.get_value("web_search.wikipedia.base_url", ""))
	base_url = override.trim_suffix("/") if override != "" else "https://%s.wikipedia.org" % language


func build_headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: " + user_agent, "Accept: application/json"])


static func build_search_query(question: String, game_name: String) -> String:
	var q := question.strip_edges()
	if game_name.strip_edges() != "":
		return "%s %s" % [game_name.strip_edges(), q]
	return q


func search_url(query: String, limit: int) -> String:
	return "%s/w/api.php?action=query&list=search&srsearch=%s&srlimit=%d&format=json&origin=*" % [base_url, query.uri_encode(), limit]


func summary_url(title: String) -> String:
	return "%s/api/rest_v1/page/summary/%s" % [base_url, title.replace(" ", "_").uri_encode()]


## Titles from a MediaWiki search response.
static func parse_search(parsed) -> PackedStringArray:
	var titles := PackedStringArray()
	if typeof(parsed) != TYPE_DICTIONARY:
		return titles
	var query = parsed.get("query", {})
	if typeof(query) != TYPE_DICTIONARY:
		return titles
	for hit in query.get("search", []):
		if typeof(hit) == TYPE_DICTIONARY and str(hit.get("title", "")) != "":
			titles.append(str(hit.get("title", "")))
	return titles


## One {title, url, text, source} from a REST summary, or {} for disambiguation / missing pages.
static func parse_summary(parsed) -> Dictionary:
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var kind := str(parsed.get("type", "standard"))
	if kind == "disambiguation" or kind == "not_found" or kind.begins_with("https://mediawiki.org/wiki/HyperSwitch/errors"):
		return {}
	var text := str(parsed.get("extract", "")).strip_edges()
	if text == "":
		text = str(parsed.get("description", "")).strip_edges()
	if text == "":
		return {}
	var url := ""
	var urls = parsed.get("content_urls", {})
	if typeof(urls) == TYPE_DICTIONARY and typeof(urls.get("desktop")) == TYPE_DICTIONARY:
		url = str(urls["desktop"].get("page", ""))
	if url == "":
		url = str(parsed.get("canonicalurl", ""))
	var title := str(parsed.get("title", ""))
	return {"title": title, "url": url, "text": text, "source": url}


## Search, then summarize the top hits. Returns {ok, results: [{title,url,text,source}], error}.
func search_and_summarize(question: String, game_name: String = "", pages: int = -1) -> Dictionary:
	var out := {"ok": false, "results": [], "error": ""}
	var limit := pages if pages > 0 else max_pages
	var titles := PackedStringArray()
	var first_error := ""
	for query in [build_search_query(question, game_name), question.strip_edges()]:
		var res: Dictionary = await _get_json(search_url(query, limit))
		if not res.ok:
			first_error = res.error
			continue
		titles = parse_search(res.data)
		if titles.size() > 0:
			break
		if game_name == "":
			break
	if titles.is_empty():
		out.error = first_error if first_error != "" else "Wikipedia found nothing for that."
		return out
	for title in titles:
		if out.results.size() >= limit:
			break
		var res: Dictionary = await _get_json(summary_url(title))
		if not res.ok:
			FiloLog.debug("Wikipedia summary failed for '%s': %s" % [title, res.error])
			continue
		var entry := parse_summary(res.data)
		if not entry.is_empty():
			out.results.append(entry)
	out.ok = out.results.size() > 0
	if not out.ok and out.error == "":
		out.error = "Wikipedia pages could not be summarized."
	return out


func _get_json(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	http.accept_gzip = true
	add_child(http)
	var started := Time.get_ticks_msec()
	var err := http.request(url, build_headers(), HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Could not start the Wikipedia request (error %d)." % err, "data": null}
	var res: Array = await http.request_completed
	http.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	var raw: PackedByteArray = res[3]
	FiloLog.debug("Wikipedia HTTP %d in %d ms (%s)" % [code, Time.get_ticks_msec() - started, url.left(90)])
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": ClaudeClient._result_error(result).replace("Claude", "Wikipedia"), "data": null}
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if code == 404:
		return {"ok": true, "error": "", "data": {"type": "not_found"}}
	if code != 200:
		return {"ok": false, "error": "Wikipedia returned HTTP %d." % code, "data": null}
	if parsed == null:
		return {"ok": false, "error": "Wikipedia returned something that isn't JSON.", "data": null}
	return {"ok": true, "error": "", "data": parsed}
