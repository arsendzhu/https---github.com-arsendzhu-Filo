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


# ---------------------------------------------------------------------------
# Any MediaWiki site (English Wikipedia, and every Fandom game wiki — same API).
# `site` = {"base_url": "https://x.fandom.com", "api_path": "/api.php", "name": "Sekiro wiki"};
# api_path defaults to "/w/api.php" (Wikipedia's layout). Used by the research agent's
# wiki_search / wiki_page tools; the summary flow above is unchanged.
# ---------------------------------------------------------------------------

static func site_api(site: Dictionary) -> String:
	return str(site.get("base_url", "")).trim_suffix("/") + str(site.get("api_path", "/w/api.php"))


static func page_url(site: Dictionary, title: String) -> String:
	return str(site.get("base_url", "")).trim_suffix("/") + "/wiki/" + title.replace(" ", "_").uri_encode()


## {ok, results: [{title, snippet, url}], error}
func mw_search(site: Dictionary, query: String, limit: int = 5) -> Dictionary:
	var out := {"ok": false, "results": [], "error": ""}
	var url := "%s?action=query&list=search&srsearch=%s&srlimit=%d&format=json&formatversion=2" % [site_api(site), query.uri_encode(), clampi(limit, 1, 10)]
	var res: Dictionary = await _get_json(url)
	if not res.ok:
		out.error = res.error
		return out
	for hit in (res.data.get("query", {}) if typeof(res.data) == TYPE_DICTIONARY else {}).get("search", []):
		if typeof(hit) != TYPE_DICTIONARY:
			continue
		var title := str(hit.get("title", ""))
		if title == "":
			continue
		out.results.append({
			"title": title,
			"snippet": html_to_text(str(hit.get("snippet", ""))).left(220),
			"url": page_url(site, title),
		})
	out.ok = true
	return out


## Does this site answer MediaWiki API calls? {ok, sitename, error}
func mw_probe(site: Dictionary) -> Dictionary:
	var out := {"ok": false, "sitename": "", "error": ""}
	var res: Dictionary = await _get_json("%s?action=query&meta=siteinfo&format=json" % site_api(site))
	if not res.ok:
		out.error = res.error
		return out
	var general = (res.data.get("query", {}) if typeof(res.data) == TYPE_DICTIONARY else {}).get("general", {})
	if typeof(general) == TYPE_DICTIONARY and str(general.get("sitename", "")) != "":
		out.ok = true
		out.sitename = str(general.sitename)
	else:
		out.error = "not a MediaWiki API"
	return out


## Cleaned plain text of a page, optionally just one section. {ok, title, url, text, sections, error}
func mw_page(site: Dictionary, title: String, section: String = "", max_chars: int = 6000) -> Dictionary:
	var out := {"ok": false, "title": title, "url": "", "text": "", "sections": PackedStringArray(), "error": ""}
	var url := "%s?action=parse&page=%s&prop=text&redirects=1&disabletoc=1&format=json&formatversion=2" % [site_api(site), title.replace(" ", "_").uri_encode()]
	var res: Dictionary = await _get_json(url)
	if not res.ok:
		out.error = res.error
		return out
	var data = res.data
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("parse")) != TYPE_DICTIONARY:
		out.error = "No page called '%s' on that wiki. Try wiki_search first." % title
		return out
	var parse: Dictionary = data["parse"]
	out.title = str(parse.get("title", title))
	out.url = page_url(site, out.title)
	var text := html_to_text(str(parse.get("text", "")))
	out.sections = section_titles(text)
	if section.strip_edges() != "":
		var body := section_of(text, section)
		if body == "":
			out.error = "That page has no section like '%s'. Sections: %s" % [section, ", ".join(out.sections)]
			return out
		text = body
	elif out.sections.size() > 0:
		text = "Sections: %s\n\n%s" % [", ".join(out.sections), text]
	out.text = truncate_text(text, max_chars)
	out.ok = out.text.strip_edges() != ""
	if not out.ok:
		out.error = "That page is empty."
	return out


## HTML -> readable plain text: drops scripts, styles, comments, navboxes, references and
## edit links; keeps headings as "## Title", list items as "- x", table cells joined by " | ".
static func html_to_text(html: String) -> String:
	var t := html
	for pattern in [
		"(?s)<!--.*?-->",
		"(?is)<(script|style|noscript|svg|iframe)\\b.*?</\\1>",
		"(?is)<table[^>]*class=\"[^\"]*navbox[^\"]*\".*?</table>",
		"(?is)<sup[^>]*class=\"[^\"]*reference[^\"]*\".*?</sup>",
		"(?is)<span[^>]*class=\"[^\"]*mw-editsection[^\"]*\".*?</span>\\s*</span>|(?is)<span[^>]*class=\"[^\"]*mw-editsection[^\"]*\".*?</span>",
	]:
		var re := RegEx.new()
		re.compile(pattern)
		t = re.sub(t, "", true)
	var subs := [
		["(?is)<h([1-6])[^>]*>(.*?)</h\\1>", "\n\n## $2\n"],
		["(?i)<li[^>]*>", "\n- "],
		["(?i)</(p|div|tr|ul|ol|table|section|blockquote)>", "\n"],
		["(?i)<br\\s*/?>", "\n"],
		["(?i)</(td|th)>", " | "],
		["<[^>]+>", ""],
	]
	for pair in subs:
		var re2 := RegEx.new()
		re2.compile(pair[0])
		t = re2.sub(t, pair[1], true)
	t = decode_entities(t)
	t = sanitize_text(t)
	var trailing := RegEx.new()
	trailing.compile("[ \\t]*\\|[ \\t]*(?=\\n|$)")
	t = trailing.sub(t, "", true)
	var ws := RegEx.new()
	ws.compile("[ \\t\\x{a0}]+")
	t = ws.sub(t, " ", true)
	var blank := RegEx.new()
	blank.compile("\\n[ \\t]*(?:\\n[ \\t]*){2,}")
	t = blank.sub(t, "\n\n", true)
	return t.strip_edges()


static func decode_entities(t: String) -> String:
	var out := t.replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'").replace("&ndash;", "–").replace("&mdash;", "—")
	var num := RegEx.new()
	num.compile("&#(x?)([0-9a-fA-F]+);")
	for m in num.search_all(out):
		var code := m.get_string(2).hex_to_int() if m.get_string(1) != "" else int(m.get_string(2))
		if code > 8 and code < 0x110000:
			out = out.replace(m.get_string(), String.chr(code))
	return out.replace("&amp;", "&")


## Removes control characters (keeps \n and \t) so nothing odd reaches the model or the log.
static func sanitize_text(t: String) -> String:
	var re := RegEx.new()
	re.compile("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]")
	return re.sub(t, "", true)


static func truncate_text(t: String, max_chars: int) -> String:
	if max_chars <= 0 or t.length() <= max_chars:
		return t
	var cut := t.left(max_chars)
	var para := cut.rfind("\n")
	if para > max_chars * 0.6:
		cut = cut.left(para)
	return cut.strip_edges() + "\n[truncated]"


static func section_titles(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in text.split("\n"):
		if line.begins_with("## "):
			var name := line.substr(3).strip_edges()
			if name != "" and not out.has(name):
				out.append(name)
	return out


## The text of the section whose heading contains `name` (case-insensitive), heading included.
static func section_of(text: String, name: String) -> String:
	var want := name.strip_edges().to_lower()
	var lines := text.split("\n")
	var collecting := false
	var out := PackedStringArray()
	for line in lines:
		if line.begins_with("## "):
			if collecting:
				break
			if line.substr(3).strip_edges().to_lower().contains(want):
				collecting = true
		if collecting:
			out.append(line)
	return "\n".join(out).strip_edges()


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
