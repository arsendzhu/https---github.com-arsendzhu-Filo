class_name NimConnection
extends RefCounted
## One persistent HTTPS connection (HTTP/1.1 keep-alive) to the NIM endpoint, so the tool loop's 2-3
## sequential requests do not each pay DNS + TCP + TLS (~150-400 ms every time), plus streaming: the
## body is handed to `on_chunk` as it arrives (server-sent events for chat completions).
##
## Godot's HTTPRequest opens a new connection per request; this wraps the low-level HTTPClient and
## polls it on process_frame. A connection that the server closed while idle is detected (the request
## fails before any response byte) and retried once on a fresh connection. Everything is bounded by
## explicit timeouts. The API key is only ever part of the headers the caller passes in and is never logged.

var host := ""
var port := 443
var tls := true
var connect_timeout := 6.0
var reused_last := false
var connects := 0                     # how many times a fresh connection was opened (tests / logging)
var _http := HTTPClient.new()
var _busy := false
var _tree: SceneTree


func _init(tree: SceneTree = null) -> void:
	_tree = tree if tree != null else (Engine.get_main_loop() as SceneTree)


## "https://integrate.api.nvidia.com/v1" -> host, port, tls (the path prefix stays with the caller).
static func parse_base(base_url: String) -> Dictionary:
	var scheme := "https"
	var rest := base_url
	if base_url.contains("://"):
		scheme = base_url.get_slice("://", 0).to_lower()
		rest = base_url.get_slice("://", 1)
	var hostport := rest.get_slice("/", 0)
	var prefix := rest.substr(hostport.length())
	var h := hostport
	var p := 443 if scheme == "https" else 80
	if hostport.contains(":"):
		h = hostport.get_slice(":", 0)
		p = int(hostport.get_slice(":", 1))
	return {"host": h, "port": p, "tls": scheme == "https", "prefix": prefix.trim_suffix("/")}


func configure(base_url: String) -> String:
	var b := parse_base(base_url)
	if b.host != host or b.port != port or b.tls != tls:
		close()
	host = b.host
	port = b.port
	tls = b.tls
	return b.prefix


func close() -> void:
	_http.close()


func is_connected_now() -> bool:
	return _http.get_status() == HTTPClient.STATUS_CONNECTED


## opts: timeout (seconds for the whole request), on_chunk: Callable(PackedByteArray) called for each body chunk
## (the body is then not collected).
## Returns {ok, status, headers, body, error, timed_out, latency_ms, ttfb_ms, reused}.
func request(method: int, path: String, headers: PackedStringArray, body: String, opts: Dictionary = {}) -> Dictionary:
	var out := {"ok": false, "status": 0, "headers": [], "body": PackedByteArray(), "error": "", "timed_out": false, "latency_ms": 0, "ttfb_ms": -1, "reused": false}
	if _busy:
		out.error = "connection busy"
		return out
	_busy = true
	var t0 := Time.get_ticks_msec()
	var timeout := float(opts.get("timeout", 30.0))
	var deadline := t0 + int(timeout * 1000.0)
	var attempt := 0
	while attempt < 2:
		attempt += 1
		var was_open := is_connected_now()
		var res := await _one_attempt(method, path, headers, body, opts, deadline)
		res["reused"] = was_open
		reused_last = was_open
		# a stale keep-alive connection fails before any response byte: retry once on a fresh connection
		if not res.ok and was_open and int(res.status) == 0 and not res.timed_out and attempt == 1 and res.ttfb_ms < 0:
			_http.close()
			continue
		out = res
		break
	out.latency_ms = Time.get_ticks_msec() - t0
	_busy = false
	return out


func _one_attempt(method: int, path: String, headers: PackedStringArray, body: String, opts: Dictionary, deadline: int) -> Dictionary:
	var out := {"ok": false, "status": 0, "headers": [], "body": PackedByteArray(), "error": "", "timed_out": false, "latency_ms": 0, "ttfb_ms": -1, "reused": false}
	var t0 := Time.get_ticks_msec()
	var on_chunk: Callable = opts.get("on_chunk", Callable())
	if not await _ensure_connected(deadline, out):
		return out
	var err := _http.request(method, path, headers, body)
	if err != OK:
		out.error = "could not send the request (error %d)" % err
		_http.close()
		return out
	while true:
		if Time.get_ticks_msec() > deadline:
			out.timed_out = true
			out.error = "timeout"
			_http.close()          # a half-read response cannot be reused
			return out
		_http.poll()
		var st := _http.get_status()
		if st == HTTPClient.STATUS_REQUESTING:
			await _tree.process_frame
			continue
		if st == HTTPClient.STATUS_BODY or st == HTTPClient.STATUS_CONNECTED:
			break
		out.error = "connection lost (status %d)" % st
		_http.close()
		return out
	if not _http.has_response():
		# a keep-alive connection closed by the server answers a request with an immediate "connected, no response"
		out.error = "no response"
		_http.close()
		return out
	out.status = _http.get_response_code()
	out.headers = _http.get_response_headers()
	out.ttfb_ms = Time.get_ticks_msec() - t0
	if out.status != 200:
		on_chunk = Callable()        # an error body is collected (it carries the reason), never streamed
	var collected := PackedByteArray()
	while _http.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			out.timed_out = true
			out.error = "timeout"
			_http.close()
			return out
		_http.poll()
		var chunk := _http.read_response_body_chunk()
		if chunk.size() > 0:
			if on_chunk.is_valid():
				on_chunk.call(chunk)
			else:
				collected.append_array(chunk)
		else:
			await _tree.process_frame
	out.body = collected
	out.ok = true
	return out


func _ensure_connected(deadline: int, out: Dictionary) -> bool:
	if is_connected_now():
		return true
	_http.close()
	var t0 := Time.get_ticks_msec()
	var err := _http.connect_to_host(host, port, TLSOptions.client() if tls else null)
	if err != OK:
		out.error = "could not connect (error %d)" % err
		return false
	connects += 1
	var limit := mini(deadline, t0 + int(connect_timeout * 1000.0))
	while true:
		_http.poll()
		var st := _http.get_status()
		if st == HTTPClient.STATUS_CONNECTED:
			return true
		if st == HTTPClient.STATUS_CONNECTING or st == HTTPClient.STATUS_RESOLVING:
			if Time.get_ticks_msec() > limit:
				out.timed_out = true
				out.error = "connect timeout"
				_http.close()
				return false
			await _tree.process_frame
			continue
		out.error = "could not connect (status %d)" % st
		_http.close()
		return false
	return false
