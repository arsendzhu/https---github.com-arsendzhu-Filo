class_name WebTools
extends Node
## The research agent's two general-web tools:
##   web_search(query)  — behind a small provider interface (register_provider()), so the
##                        search backend can be swapped. Built in: "duckduckgo" (keyless HTML
##                        results) and "wikipedia" (the same Wikipedia search Filo already used).
##   fetch_page(url)    — readable plain text of a page, hardened against SSRF: http/https only,
##                        every hop (including redirects) is checked, private/loopback/link-local
##                        addresses are refused, redirects and body size are capped.
## Everything returned is untrusted data; the agent wraps and caps it before the model sees it.

const ALLOWED_PORTS := [80, 443, 8080, 8443]

var provider := "duckduckgo"
var user_agent := "Filo/0.1 (game overlay companion; local use)"
var timeout_sec := 10.0
var max_bytes := 1500000
var max_redirects := 3
var search_endpoint := "https://html.duckduckgo.com/html/"
var wiki: WikipediaClient
## Test hook: func(host: String) -> PackedStringArray of IPs. Empty Callable = real DNS.
var resolver := Callable()
var _providers := {}


func _init() -> void:
	_providers = {"duckduckgo": _search_duckduckgo, "wikipedia": _search_wikipedia}


func configure(cfg: FiloConfig, wikipedia: WikipediaClient) -> void:
	wiki = wikipedia
	provider = str(cfg.get_value("research.search_provider", "duckduckgo")).to_lower()
	user_agent = str(cfg.get_value("web_search.wikipedia.user_agent", user_agent))
	timeout_sec = float(cfg.get_value("research.tool_timeout", 10.0))
	max_bytes = int(cfg.get_value("research.max_fetch_bytes", 1500000))
	max_redirects = int(cfg.get_value("research.max_redirects", 3))
	var endpoint := str(cfg.get_value("research.search_endpoint", ""))
	if endpoint != "":
		search_endpoint = endpoint


## Add or replace a search backend: fn(query: String, limit: int) -> {ok, results: [{title,url,snippet}], error}
func register_provider(provider_name: String, fn: Callable) -> void:
	_providers[provider_name.to_lower()] = fn


func web_search(query: String, limit: int = 5) -> Dictionary:
	var q := query.strip_edges()
	if q == "":
		return {"ok": false, "results": [], "error": "Empty search query."}
	if not _providers.has(provider):
		return {"ok": false, "results": [], "error": "Unknown search provider '%s'." % provider}
	return await _providers[provider].call(q, limit)


func _search_wikipedia(query: String, limit: int) -> Dictionary:
	if wiki == null:
		return {"ok": false, "results": [], "error": "Wikipedia client unavailable."}
	var site := {"base_url": wiki.base_url, "api_path": "/w/api.php", "name": "Wikipedia"}
	return await wiki.mw_search(site, query, limit)


func _search_duckduckgo(query: String, limit: int) -> Dictionary:
	var out := {"ok": false, "results": [], "error": ""}
	var res: Dictionary = await _http_get(search_endpoint + "?q=" + query.uri_encode(), true)
	if not res.ok:
		out.error = res.error
		return out
	out.results = parse_duckduckgo(res.text, limit)
	out.ok = true
	if out.results.is_empty():
		out.error = "The search returned no results."
	return out


## Result anchors from DuckDuckGo's HTML endpoint. Ads and non-http links are dropped.
static func parse_duckduckgo(html: String, limit: int) -> Array:
	var results := []
	var link := RegEx.new()
	link.compile("(?is)<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>")
	var snip := RegEx.new()
	snip.compile("(?is)class=\"result__snippet\"[^>]*>(.*?)</a>")
	var snippets := snip.search_all(html)
	var i := 0
	for m in link.search_all(html):
		var url := decode_ddg_link(WikipediaClient.decode_entities(m.get_string(1)))
		if url == "" or url.contains("duckduckgo.com/y.js"):
			i += 1
			continue
		results.append({
			"title": WikipediaClient.html_to_text(m.get_string(2)).left(160),
			"url": url,
			"snippet": WikipediaClient.html_to_text(snippets[i].get_string(1)).left(240) if i < snippets.size() else "",
		})
		i += 1
		if results.size() >= limit:
			break
	return results


static func decode_ddg_link(href: String) -> String:
	var h := href
	if h.begins_with("//"):
		h = "https:" + h
	var at := h.find("uddg=")
	if at >= 0:
		var end := h.find("&", at)
		var enc := h.substr(at + 5, (end if end >= 0 else h.length()) - at - 5)
		h = enc.uri_decode()
	return h if h.begins_with("http://") or h.begins_with("https://") else ""


# --------------------------------------------------------------------- fetch_page

## {ok, url, title, text, error}
func fetch_page(url: String, max_chars: int = 6000) -> Dictionary:
	var out := {"ok": false, "url": url, "title": "", "text": "", "error": ""}
	var current := url.strip_edges()
	for hop in range(max_redirects + 1):
		var check: Dictionary = await check_url(current)
		if not check.ok:
			out.error = check.error
			return out
		var res: Dictionary = await _http_get(current, false)
		if not res.ok:
			out.error = res.error
			return out
		if res.code >= 300 and res.code < 400 and res.location != "":
			current = resolve_location(current, res.location)
			continue
		if res.code != 200:
			out.error = "The page returned HTTP %d." % res.code
			return out
		var ctype := str(res.content_type).to_lower()
		if ctype != "" and not (ctype.contains("text/html") or ctype.contains("text/plain") or ctype.contains("xhtml")):
			out.error = "That URL is not a readable web page (%s)." % ctype.get_slice(";", 0)
			return out
		out.url = current
		out.title = extract_title(res.text)
		out.text = WikipediaClient.truncate_text(article_text(res.text) if ctype.contains("html") or ctype == "" else WikipediaClient.sanitize_text(res.text), max_chars)
		out.ok = out.text.strip_edges() != ""
		if not out.ok:
			out.error = "The page had no readable text."
		return out
	out.error = "Too many redirects."
	return out


static func extract_title(html: String) -> String:
	var re := RegEx.new()
	re.compile("(?is)<title[^>]*>(.*?)</title>")
	var m := re.search(html)
	return WikipediaClient.html_to_text(m.get_string(1)).left(160) if m else ""


## Main readable text of a generic web page (drops navigation chrome first).
static func article_text(html: String) -> String:
	var re := RegEx.new()
	re.compile("(?is)<(nav|header|footer|aside|form|button|select)\\b.*?</\\1>")
	return WikipediaClient.html_to_text(re.sub(html, "", true))


static func resolve_location(base: String, location: String) -> String:
	if location.begins_with("http://") or location.begins_with("https://"):
		return location
	var parsed := parse_url(base)
	if not parsed.ok:
		return location
	var root := "%s://%s%s" % [parsed.scheme, parsed.host, (":" + str(parsed.port)) if parsed.explicit_port else ""]
	if location.begins_with("//"):
		return parsed.scheme + ":" + location
	if location.begins_with("/"):
		return root + location
	var dir := str(parsed.path).get_base_dir()
	return root + (dir if dir != "/" else "") + "/" + location


static func parse_url(url: String) -> Dictionary:
	var out := {"ok": false, "scheme": "", "host": "", "port": 0, "explicit_port": false, "path": "/", "error": ""}
	var re := RegEx.new()
	re.compile("^(https?)://([^/?#]+)([^#]*)")
	var m := re.search(url.strip_edges())
	if m == null:
		out.error = "Only http and https URLs can be fetched."
		return out
	var authority := m.get_string(2)
	if authority.contains("@"):
		out.error = "URLs with embedded credentials are not allowed."
		return out
	var host := authority
	var port := 443 if m.get_string(1) == "https" else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		host = authority.substr(1, close - 1)
		if authority.length() > close + 1 and authority[close + 1] == ":":
			port = int(authority.substr(close + 2))
			out.explicit_port = true
	elif authority.contains(":"):
		host = authority.get_slice(":", 0)
		port = int(authority.get_slice(":", 1))
		out.explicit_port = true
	out.scheme = m.get_string(1)
	out.host = host.to_lower()
	out.port = port
	out.path = m.get_string(3) if m.get_string(3) != "" else "/"
	out.ok = host != ""
	if not out.ok:
		out.error = "That URL has no host."
	return out


## Validates scheme, port and every address the host resolves to.
func check_url(url: String) -> Dictionary:
	var parsed := parse_url(url)
	if not parsed.ok:
		return {"ok": false, "error": parsed.error}
	if not ALLOWED_PORTS.has(int(parsed.port)):
		return {"ok": false, "error": "That port is not allowed."}
	var addrs := await _resolve(str(parsed.host))
	if addrs.is_empty():
		return {"ok": false, "error": "Could not look up that host."}
	for a in addrs:
		if is_blocked_ip(a):
			return {"ok": false, "error": "That address is private or local, so it is blocked."}
	return {"ok": true, "error": ""}


func _resolve(host: String) -> PackedStringArray:
	if host.is_valid_ip_address():
		return PackedStringArray([host])
	if resolver.is_valid():
		return resolver.call(host)
	var id := IP.resolve_hostname_queue_item(host)
	var waited := 0.0
	while IP.get_resolve_item_status(id) == IP.RESOLVER_STATUS_WAITING and waited < 5.0:
		await get_tree().create_timer(0.05).timeout
		waited += 0.05
	var addrs := PackedStringArray(IP.get_resolve_item_addresses(id))
	IP.erase_resolve_item(id)
	return addrs


## True for anything that is not an ordinary public unicast address (fails closed on junk).
static func is_blocked_ip(ip: String) -> bool:
	var a := ip.strip_edges().to_lower()
	if a.contains(":"):
		if a == "::" or a == "::1":
			return true
		if a.begins_with("::ffff:") and a.contains("."):
			return is_blocked_ip(a.substr(7))
		var first := a.get_slice(":", 0)
		if first.length() < 2:
			return true
		var lead := ("0000" + first).right(4).hex_to_int()
		if (lead & 0xfe00) == 0xfc00 or (lead & 0xffc0) == 0xfe80 or (lead & 0xff00) == 0xff00:
			return true
		return false
	var parts := a.split(".")
	if parts.size() != 4:
		return true
	var n := []
	for p in parts:
		if not p.is_valid_int():
			return true
		n.append(int(p))
	if n[0] == 0 or n[0] == 10 or n[0] == 127 or n[0] >= 224:
		return true
	if n[0] == 169 and n[1] == 254:
		return true
	if n[0] == 172 and n[1] >= 16 and n[1] <= 31:
		return true
	if n[0] == 192 and (n[1] == 168 or (n[1] == 0 and n[2] == 0)):
		return true
	if n[0] == 100 and n[1] >= 64 and n[1] <= 127:
		return true
	return false


## Single GET. Never follows redirects (fetch_page vets each hop itself).
## {ok, code, text, content_type, location, error}
func _http_get(url: String, follow: bool) -> Dictionary:
	var out := {"ok": false, "code": 0, "text": "", "content_type": "", "location": "", "error": ""}
	var http := HTTPRequest.new()
	http.timeout = timeout_sec
	http.accept_gzip = true
	http.body_size_limit = max_bytes
	http.max_redirects = 3 if follow else 0
	add_child(http)
	var headers := PackedStringArray(["User-Agent: " + ("Mozilla/5.0 (Macintosh) Filo/0.1" if follow else user_agent), "Accept: text/html,text/plain;q=0.9,*/*;q=0.5"])
	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		out.error = "Could not start the request (error %d)." % err
		return out
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		out.error = "The page is too large to read."
		return out
	if res[0] != HTTPRequest.RESULT_SUCCESS:
		out.error = "Could not load the page (%s)." % ("timed out" if res[0] == HTTPRequest.RESULT_TIMEOUT else "network error")
		return out
	out.code = res[1]
	for h in res[2]:
		var hs := str(h)
		var low := hs.to_lower()
		if low.begins_with("content-type:"):
			out.content_type = hs.substr(13).strip_edges()
		elif low.begins_with("location:"):
			out.location = hs.substr(9).strip_edges()
	out.text = (res[3] as PackedByteArray).get_string_from_utf8()
	out.ok = true
	return out
