@tool
extends Node
## Optional online translation fallback for words missing from the local
## dictionaries. Results are cached on disk, so the second hover is instant.

signal resolved(query: String, kind: String, zh: String, provider: String, cached: bool, context: String)
signal failed(query: String, kind: String, message: String)

const CACHE_VERSION := 1
const CACHE_DIR_NAME := "HoverTranslator"
const DEFAULT_URL := "https://api.mymemory.translated.net/get?q={query}&langpair=en%7Czh-CN"
const MAX_CACHE := 5000
const MAX_QUERY_CHARS := 240

var enabled := true
var endpoint := DEFAULT_URL
var timeout := 8.0

var _cache: Dictionary = {}
var _cache_path := ""
var _queue: Array[Dictionary] = []
var _pending: Dictionary = {}
var _busy := false
var _current: Dictionary = {}
var _http: HTTPRequest
var _last_error := ""
var _cooldown_until := 0
var _dirty := false
var _save_delay := 0.0
var _requests := 0
var _resolved_count := 0
var _cache_hits := 0

func _ready() -> void:
	set_process(true)
	_cache_path = _platform_cache_path()
	DirAccess.make_dir_recursive_absolute(_cache_path.get_base_dir())
	_http = HTTPRequest.new()
	_http.timeout = timeout
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_load_cache()

func _platform_cache_path() -> String:
	var home := OS.get_environment("HOME")
	var root := ""
	match OS.get_name():
		"Windows":
			var profile := OS.get_environment("USERPROFILE")
			if profile == "":
				profile = home
			root = profile.path_join("AppData/LocalLow").path_join(CACHE_DIR_NAME)
		"macOS":
			if home != "":
				root = home.path_join("Library/Application Support").path_join(CACHE_DIR_NAME)
		"Linux":
			if home != "":
				var data_home := OS.get_environment("XDG_DATA_HOME")
				if data_home == "":
					data_home = home.path_join(".local/share")
				root = data_home.path_join(CACHE_DIR_NAME)
	if root == "":
		root = OS.get_user_data_dir().path_join(CACHE_DIR_NAME)
	return root.path_join("translation_cache.json")

func _process(delta: float) -> void:
	if _dirty:
		_save_delay -= delta
		if _save_delay <= 0.0:
			_save_cache()

func get_cached(text: String, kind: String) -> String:
	var entry: Dictionary = _cache.get(_key(text, kind), {})
	return String(entry.get("zh", ""))

func has_pending(text: String, kind: String) -> bool:
	return _pending.has(_key(text, kind))

func request(text: String, kind: String, query_text: String = "", context: String = "") -> bool:
	if not enabled:
		return false
	var clean := text.strip_edges()
	if clean == "":
		return false
	var key := _key(clean, kind)
	var entry: Dictionary = _cache.get(key, {})
	if String(entry.get("zh", "")) != "":
		_cache_hits += 1
		resolved.emit(clean, kind, String(entry["zh"]), String(entry.get("provider", "缓存")), true, String(entry.get("context", context)))
		return true
	if _pending.has(key):
		return true
	if Time.get_ticks_msec() < _cooldown_until:
		return false
	if _queue.size() >= 8:
		return false
	var query := query_text.strip_edges()
	if query == "":
		query = clean
	if query.length() > MAX_QUERY_CHARS:
		return false
	_queue.append({"text": clean, "kind": kind, "query": query, "key": key, "context": context})
	_pending[key] = true
	_pump()
	return true

func _pump() -> void:
	if _busy or _queue.is_empty() or _http == null:
		return
	_current = _queue.pop_front()
	_busy = true
	_requests += 1
	var query := String(_current.get("query", ""))
	var url := endpoint.replace("{query}", query.uri_encode())
	var err := _http.request(url)
	if err != OK:
		_finish_fail("无法发起网络请求（错误码 %d）" % err, 3000)

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var item := _current
	_current = {}
	_busy = false
	if item.is_empty():
		_pump()
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish_fail(_result_name(result), 12000, item)
		return
	if response_code == 429:
		_finish_fail("在线翻译请求太频繁，请稍后再试", 60000, item)
		return
	if response_code != 200:
		_finish_fail("在线翻译服务返回 HTTP %d" % response_code, 12000, item)
		return
	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_finish_fail("在线翻译返回了无法解析的数据", 3000, item)
		return
	var data: Dictionary = parsed
	if bool(data.get("quotaFinished", false)):
		_finish_fail("在线翻译今日额度已用完", 600000, item)
		return
	var response_status := int(data.get("responseStatus", 200))
	if response_status != 200:
		var detail := String(data.get("responseDetails", "")).strip_edges()
		if detail == "":
			detail = "在线翻译服务拒绝了请求"
		_finish_fail(detail, 12000, item)
		return
	var rd = data.get("responseData", {})
	if typeof(rd) != TYPE_DICTIONARY:
		_finish_fail("在线翻译没有返回译文", 3000, item)
		return
	var zh := _clean_translation(String((rd as Dictionary).get("translatedText", "")))
	if zh == "":
		_finish_fail("在线翻译没有返回译文", 3000, item)
		return
	var query := String(item.get("query", ""))
	if zh.to_lower() == query.to_lower():
		_finish_fail("在线翻译没有产生新译文", 3000, item)
		return
	_finish_success(item, zh, "MyMemory")

func _finish_success(item: Dictionary, zh: String, provider: String) -> void:
	var key := String(item.get("key", ""))
	_cache[key] = {
		"zh": zh,
		"provider": provider,
		"ts": int(Time.get_unix_time_from_system()),
		"context": String(item.get("context", "")),
	}
	_pending.erase(key)
	_resolved_count += 1
	_dirty = true
	_save_delay = 1.5
	_trim_cache()
	resolved.emit(String(item.get("text", "")), String(item.get("kind", "ui")), zh, provider, false, String(item.get("context", "")))
	_pump()

func _finish_fail(message: String, cooldown_ms: int, item: Dictionary = {}) -> void:
	var actual := item
	if actual.is_empty():
		actual = _current
		_current = {}
		_busy = false
	_last_error = message
	_cooldown_until = Time.get_ticks_msec() + cooldown_ms
	if not actual.is_empty():
		_pending.erase(String(actual.get("key", "")))
		failed.emit(String(actual.get("text", "")), String(actual.get("kind", "ui")), message)
	_pump()

func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接在线翻译服务"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "无法解析在线翻译服务域名"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "在线翻译连接中断"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "在线翻译 TLS 握手失败"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "在线翻译没有响应"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "在线翻译响应过大"
		HTTPRequest.RESULT_REQUEST_FAILED:
			return "在线翻译请求失败"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			return "在线翻译重定向过多"
		HTTPRequest.RESULT_TIMEOUT:
			return "在线翻译超时"
	return "在线翻译网络错误（%d）" % result

func _clean_translation(raw: String) -> String:
	var t := raw.strip_edges()
	t = t.replace("&quot;", "\"")
	t = t.replace("&#39;", "'")
	t = t.replace("&apos;", "'")
	t = t.replace("&amp;", "&")
	t = t.replace("&lt;", "<")
	t = t.replace("&gt;", ">")
	var re := RegEx.new()
	re.compile("<[^>]+>")
	t = re.sub(t, "", true)
	t = t.replace("\r", " ").replace("\n", " ").strip_edges()
	while t.length() > 1 and (t.begins_with("\"") and t.ends_with("\"")):
		t = t.substr(1, t.length() - 2).strip_edges()
	return t

func status_text() -> String:
	if not enabled:
		return "在线兜底：已关闭"
	if _last_error != "" and Time.get_ticks_msec() < _cooldown_until:
		return "在线兜底：" + _last_error
	if _busy:
		return "在线兜底：正在翻译…"
	return "在线兜底：就绪 · 缓存 %d 条" % _cache.size()

func last_error() -> String:
	return _last_error

func clear_cache() -> void:
	_cache.clear()
	_dirty = true
	_save_delay = 0.0
	_last_error = ""
	cooldown_until_reset()

func cooldown_until_reset() -> void:
	_cooldown_until = 0

func stats() -> Dictionary:
	return {
		"cache": _cache.size(),
		"requests": _requests,
		"resolved": _resolved_count,
		"cache_hits": _cache_hits,
	}

func _key(text: String, kind: String) -> String:
	return kind.to_lower() + "|" + text.to_lower().strip_edges()

func _trim_cache() -> void:
	if _cache.size() <= MAX_CACHE:
		return
	var entries: Array = []
	for k in _cache.keys():
		var e: Dictionary = _cache[k]
		entries.append([int(e.get("ts", 0)), String(k)])
	entries.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var remove_count := _cache.size() - MAX_CACHE
	for i in remove_count:
		_cache.erase(String(entries[i][1]))

func _load_cache() -> void:
	_cache.clear()
	if not FileAccess.file_exists(_cache_path):
		return
	var text := FileAccess.get_file_as_string(_cache_path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	var entries = data.get("entries", {})
	if typeof(entries) != TYPE_DICTIONARY:
		# Also accept an older flat {key: "译文"} cache.
		entries = data
	for k in (entries as Dictionary).keys():
		var v = (entries as Dictionary)[k]
		if typeof(v) == TYPE_DICTIONARY:
			var e: Dictionary = v
			var zh := String(e.get("zh", "")).strip_edges()
			if zh != "":
				_cache[String(k)] = {
					"zh": zh,
					"provider": String(e.get("provider", "缓存")),
					"ts": int(e.get("ts", 0)),
				}
		elif typeof(v) == TYPE_STRING and String(v).strip_edges() != "":
			_cache[String(k)] = {"zh": String(v).strip_edges(), "provider": "缓存", "ts": 0}

func _save_cache() -> void:
	_dirty = false
	_save_delay = 0.0
	var data := {"version": CACHE_VERSION, "entries": _cache}
	var f := FileAccess.open(_cache_path, FileAccess.WRITE)
	if f == null:
		_last_error = "无法写入在线翻译缓存"
		return
	f.store_string(JSON.stringify(data))
	f.close()
