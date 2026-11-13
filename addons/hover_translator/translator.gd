@tool
extends RefCounted
## Layered English -> Chinese lookup for the Godot editor.
##
## Dictionary layout:
##   data/main_zh.json                non-code UI / general
##   data/code/godot_api_zh.json      Godot API, classes, properties
##   data/code/grammar_zh.json        GDScript keywords / operators
##   data/code/custom_api_zh.json     user-defined identifiers
##   data/tmp/code_zh.json            staged code translations
##   data/tmp/other_zh.json           staged non-code translations
##   review/online_review.json        export for AI review / import

const SEED_DIR := "res://addons/hover_translator/data/"
const REVIEW_FILE := "online_review.json"
const REVIEW_GUIDE := "AI_REVIEW_GUIDE.md"
const LIVE_ROOT_NAME := "HoverTranslator"

const DICT_FILES := [
	"main_zh.json",
	"code/godot_api_zh.json",
	"code/grammar_zh.json",
	"code/custom_api_zh.json",
	"tmp/code_zh.json",
	"tmp/other_zh.json",
]

const BUCKET_MAIN := "main"
const BUCKET_GODOT := "godot_api"
const BUCKET_GRAMMAR := "grammar"
const BUCKET_CUSTOM := "custom_api"
const BUCKET_TMP_CODE := "tmp_code"
const BUCKET_TMP_OTHER := "tmp_other"

var main_exact: Dictionary = {}
var godot_api_exact: Dictionary = {}
var grammar_exact: Dictionary = {}
var custom_api_exact: Dictionary = {}
var tmp_code_exact: Dictionary = {}
var tmp_other_exact: Dictionary = {}

var word_map: Dictionary = {}
var lower_phrase: Dictionary = {}
var zh_to_en: Dictionary = {}

var _bbcode := RegEx.new()
var _spaces := RegEx.new()
var _camel1 := RegEx.new()
var _camel2 := RegEx.new()
var _alpha_digit := RegEx.new()
var _file_ext := RegEx.new()
var _tags := RegEx.new()

var _review: Dictionary = {}
var _review_path := ""
var _data_dir := ""
var _live_root := ""
var last_error := ""

func _init() -> void:
	_bbcode.compile("\\[[^\\]]*\\]")
	_spaces.compile("\\s+")
	_camel1.compile("([a-z0-9])([A-Z])")
	_camel2.compile("([A-Z]+)([A-Z][a-z])")
	_alpha_digit.compile("([A-Za-z])([0-9])")
	_file_ext.compile("\\.([A-Za-z0-9]+)$")
	_tags.compile("<[^>]+>")
	_live_root = OS.get_environment("USERPROFILE").path_join("AppData/LocalLow").path_join(LIVE_ROOT_NAME)
	_data_dir = _live_root.path_join("data")
	_review_path = _live_root.path_join("review").path_join(REVIEW_FILE)
	_ensure_live_data()
	reload()

func _ensure_live_data() -> void:
	DirAccess.make_dir_recursive_absolute(_data_dir)
	for rel in DICT_FILES:
		var live := _data_dir.path_join(rel)
		if FileAccess.file_exists(live):
			continue
		DirAccess.make_dir_recursive_absolute(live.get_base_dir())
		var content := "{}\n"
		var seed: String = SEED_DIR + String(rel)
		if FileAccess.file_exists(seed):
			content = FileAccess.get_file_as_string(seed)
		var f := FileAccess.open(live, FileAccess.WRITE)
		if f != null:
			f.store_string(content)
			f.close()
	var review_dir := _review_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(review_dir)
	if not FileAccess.file_exists(_review_path):
		var f2 := FileAccess.open(_review_path, FileAccess.WRITE)
		if f2 != null:
			f2.store_string("{\n  \"version\": 1,\n  \"entries\": {}\n}\n")
			f2.close()
	var guide := review_dir.path_join(REVIEW_GUIDE)
	if not FileAccess.file_exists(guide):
		var seed_guide := "res://addons/hover_translator/review/" + REVIEW_GUIDE
		if FileAccess.file_exists(seed_guide):
			var g := FileAccess.open(guide, FileAccess.WRITE)
			if g != null:
				g.store_string(FileAccess.get_file_as_string(seed_guide))
				g.close()

func reload() -> void:
	main_exact.clear()
	godot_api_exact.clear()
	grammar_exact.clear()
	custom_api_exact.clear()
	tmp_code_exact.clear()
	tmp_other_exact.clear()
	word_map.clear()
	lower_phrase.clear()

	_load_file("main_zh.json", main_exact)
	_load_file("code/godot_api_zh.json", godot_api_exact)
	_load_file("code/grammar_zh.json", grammar_exact)
	_load_file("code/custom_api_zh.json", custom_api_exact)
	_load_file("tmp/code_zh.json", tmp_code_exact)
	_load_file("tmp/other_zh.json", tmp_other_exact)
	_apply_overrides()
	_build_indexes()
	_build_reverse()
	_load_review()

func _load_file(file_name: String, target: Dictionary) -> void:
	var path := _data_dir.path_join(file_name)
	if not FileAccess.file_exists(path):
		push_warning("Hover Translator: missing dictionary " + path)
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Hover Translator: invalid dictionary " + path)
		return
	for k in parsed.keys():
		target[String(k)] = String(parsed[k])

func _apply_overrides() -> void:
	var fixes := {
		"Script": "脚本",
		"Volume": "音量",
		"Free": "释放",
		"Process": "处理",
		"Offset": "偏移",
		"Centered": "居中",
		"Flip H": "水平翻转",
		"Flip V": "垂直翻转",
		"Animation": "动画",
		"Region": "区域",
		"Mode": "模式",
		"Inherit": "继承",
		"Filter Properties": "过滤属性",
		"Add Child": "添加子节点",
		"Queue Free": "排队释放（安全删除节点）",
		"Node2D": "2D 节点",
		"CanvasItem": "画布项",
		"Sprite2D": "2D 精灵",
		"Enabled": "启用",
		"Enable": "启用",
		"Thread Group": "线程组",
		"Visible": "可见",
		"Position": "位置",
		"Rotation": "旋转",
		"Scale": "缩放",
	}
	for k in fixes.keys():
		var v := String(fixes[k])
		if main_exact.has(k):
			main_exact[k] = v
		if godot_api_exact.has(k):
			godot_api_exact[k] = v
		if grammar_exact.has(k):
			grammar_exact[k] = v
		if custom_api_exact.has(k):
			custom_api_exact[k] = v

func _build_indexes() -> void:
	var ordered: Array = [
		[main_exact, BUCKET_MAIN],
		[godot_api_exact, BUCKET_GODOT],
		[grammar_exact, BUCKET_GRAMMAR],
		[custom_api_exact, BUCKET_CUSTOM],
		[tmp_code_exact, BUCKET_TMP_CODE],
		[tmp_other_exact, BUCKET_TMP_OTHER],
	]
	for pair in ordered:
		var src: Dictionary = pair[0]
		for k in src.keys():
			var key := String(k).strip_edges()
			if key == "":
				continue
			var low := key.to_lower()
			lower_phrase[low] = src[k]
			if _is_single_word(key):
				word_map[low] = src[k]

func _is_single_word(s: String) -> bool:
	if s.contains(" ") or s.contains("\n") or s.contains("\t"):
		return false
	for i in s.length():
		var c := s[i]
		if not (c == "-" or c == "'" or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z")):
			return false
	return true

func _build_reverse() -> void:
	zh_to_en.clear()
	var ordered: Array = [
		main_exact, godot_api_exact, grammar_exact, custom_api_exact,
		tmp_code_exact, tmp_other_exact,
	]
	for src in ordered:
		for en in (src as Dictionary).keys():
			var zh := String((src as Dictionary)[en])
			for variant in _zh_variants(zh):
				if variant != "":
					zh_to_en[variant] = String(en)

func _zh_variants(zh: String) -> Array[String]:
	var out: Array[String] = []
	var base := clean_text(zh)
	if base != "":
		out.append(base)
	for sep in ["；", ";", "，", ",", " / ", "/", "、"]:
		var parts := base.split(sep, false)
		for p in parts:
			var v := p.strip_edges()
			if v != "":
				out.append(v)
	var no_paren := base
	var p1 := no_paren.find("（")
	if p1 > 0:
		no_paren = no_paren.substr(0, p1).strip_edges()
	if no_paren != base and no_paren != "":
		out.append(no_paren)
	return out

func reverse_lookup(zh: String) -> String:
	var key := clean_text(zh)
	if zh_to_en.has(key):
		return String(zh_to_en[key])
	for v in _zh_variants(zh):
		if zh_to_en.has(v):
			return String(zh_to_en[v])
	return ""

func clean_text(raw: String) -> String:
	var t := raw
	t = _bbcode.sub(t, "", true)
	t = t.replace("&", "")
	t = t.replace("\r", " ")
	t = _spaces.sub(t, " ", true).strip_edges()
	while t.ends_with(":") or t.ends_with("：") or t.ends_with("…"):
		t = t.substr(0, t.length() - 1).strip_edges()
	return t

func normalize(raw: String) -> String:
	return clean_text(raw).to_lower()

func lookup(raw: String, kind: String = "ui") -> Dictionary:
	var text := clean_text(raw)
	var empty := {
		"query": raw, "zh": "", "kind": kind, "source": "", "parts": [],
		"suggested_bucket": suggest_bucket(text, kind), "bucket": "", "staged": false,
	}
	if text == "" or not _has_letters(text):
		return empty

	var low := text.to_lower()
	var ordered: Array = []
	if kind == "code":
		ordered = [
			[godot_api_exact, BUCKET_GODOT],
			[grammar_exact, BUCKET_GRAMMAR],
			[custom_api_exact, BUCKET_CUSTOM],
			[tmp_code_exact, BUCKET_TMP_CODE],
			[main_exact, BUCKET_MAIN],
			[tmp_other_exact, BUCKET_TMP_OTHER],
		]
	else:
		ordered = [
			[main_exact, BUCKET_MAIN],
			[tmp_other_exact, BUCKET_TMP_OTHER],
			[godot_api_exact, BUCKET_GODOT],
			[grammar_exact, BUCKET_GRAMMAR],
			[custom_api_exact, BUCKET_CUSTOM],
			[tmp_code_exact, BUCKET_TMP_CODE],
		]

	for pair in ordered:
		var dict: Dictionary = pair[0]
		var bucket := String(pair[1])
		if dict.has(text):
			return _result(text, String(dict[text]), kind, "exact", bucket)
		if dict.has(low):
			return _result(text, String(dict[low]), kind, "exact", bucket)

	var file_kind := _file_kind(text)
	if file_kind != "":
		return _result(text, file_kind, "file", "file", BUCKET_MAIN)

	if _looks_like_identifier(text):
		var comp := _compose_identifier(text)
		if not comp.is_empty() and String(comp.get("zh", "")) != "":
			return comp

	if text.contains(" "):
		var comp2 := _compose_phrase(text)
		if not comp2.is_empty() and String(comp2.get("zh", "")) != "":
			return comp2

	var one := _lookup_word(low)
	if one != "":
		return _result(text, one, kind, "word", suggest_bucket(text, kind))

	return empty

func _result(query: String, zh: String, kind: String, source: String, bucket: String = "") -> Dictionary:
	var staged := bucket == BUCKET_TMP_CODE or bucket == BUCKET_TMP_OTHER
	return {
		"query": query,
		"zh": zh,
		"kind": kind,
		"source": "tmp" if staged else source,
		"parts": [],
		"bucket": bucket,
		"staged": staged,
		"suggested_bucket": suggest_bucket(query, kind) if (staged or bucket == "") else bucket,
	}

func _lookup_word(word: String) -> String:
	var low := word.to_lower()
	if word_map.has(low):
		return String(word_map[low])
	return ""

func _compose_identifier(text: String) -> Dictionary:
	var parts := split_identifier(text)
	if parts.is_empty():
		return {}
	var zh_parts: Array[String] = []
	var en_parts: Array[String] = []
	var known := 0
	for p in parts:
		var z := _lookup_word(p)
		if z == "" and p.length() > 1:
			z = _lookup_word(p.to_lower())
		if z != "":
			zh_parts.append(z)
			en_parts.append(p)
			known += 1
		else:
			zh_parts.append(p)
			en_parts.append(p)
	if known == 0:
		return {}
	var zh := ""
	for i in zh_parts.size():
		zh += zh_parts[i]
	var note := "组合释义" if known < parts.size() else "按词段翻译"
	return {
		"query": text,
		"zh": zh,
		"kind": "code",
		"source": "compose",
		"parts": en_parts,
		"note": note,
		"bucket": BUCKET_CUSTOM,
		"staged": false,
		"suggested_bucket": BUCKET_CUSTOM,
	}

func _compose_phrase(text: String) -> Dictionary:
	var words := text.split(" ", false)
	if words.size() < 2 or words.size() > 6:
		return {}
	var zh_parts: Array[String] = []
	var en_parts: Array[String] = []
	var known := 0
	for w in words:
		var clean := w.strip_edges()
		var z := _lookup_word(clean)
		if z == "":
			z = _lookup_word(clean.trim_suffix(",").trim_suffix("."))
		if z != "":
			zh_parts.append(z)
			en_parts.append(clean)
			known += 1
		else:
			zh_parts.append(clean)
			en_parts.append(clean)
	if known == 0:
		return {}
	return {
		"query": text,
		"zh": "".join(zh_parts),
		"kind": "word",
		"source": "compose",
		"parts": en_parts,
		"note": "逐词翻译" if known < words.size() else "短语",
		"bucket": BUCKET_MAIN,
		"staged": false,
		"suggested_bucket": BUCKET_MAIN,
	}

func _has_letters(s: String) -> bool:
	for i in s.length():
		var c := s[i]
		if (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			return true
	return false

func _looks_like_identifier(s: String) -> bool:
	if s.contains(" "):
		return false
	return s.contains("_") or s.contains(".") or _has_camel(s) or _has_digit_letter(s)

func is_identifier(s: String) -> bool:
	return _looks_like_identifier(s)

func _has_camel(s: String) -> bool:
	for i in range(1, s.length()):
		var prev := s[i - 1]
		var c := s[i]
		if prev >= "a" and prev <= "z" and c >= "A" and c <= "Z":
			return true
	return false

func _has_digit_letter(s: String) -> bool:
	var has_d := false
	var has_l := false
	for i in s.length():
		var c := s[i]
		if c >= "0" and c <= "9":
			has_d = true
		elif (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			has_l = true
	return has_d and has_l

func split_identifier(s: String) -> Array[String]:
	var t := s.replace("-", "_").replace(".", "_")
	var raw_parts := t.split("_", false)
	var out: Array[String] = []
	for raw in raw_parts:
		var p := String(raw)
		p = _camel1.sub(p, "$1 $2", true)
		p = _camel2.sub(p, "$1 $2", true)
		p = _alpha_digit.sub(p, "$1 $2", true)
		for piece in p.split(" ", false):
			if piece != "":
				out.append(piece)
	return out

func speech_text(raw: String) -> String:
	var text := clean_text(raw)
	if text == "":
		return ""
	if text.length() > 90 or text.split(" ").size() > 14:
		var cut := text.substr(0, 90)
		var sp := cut.rfind(" ")
		if sp > 20:
			cut = cut.substr(0, sp)
		text = cut
	var parts := split_identifier(text)
	if parts.size() > 1 and not text.contains(" "):
		return " ".join(parts)
	return text

func _file_kind(name: String) -> String:
	var m := _file_ext.search(name)
	if m == null:
		return ""
	var ext := m.get_string(1).to_lower()
	match ext:
		"tscn": return "场景文件（.tscn）"
		"scn": return "二进制场景文件（.scn）"
		"gd": return "GDScript 脚本文件（.gd）"
		"cs": return "C# 脚本文件（.cs）"
		"shader", "gdshader": return "着色器文件"
		"tres": return "文本资源文件（.tres）"
		"res": return "二进制资源文件（.res）"
		"png", "jpg", "jpeg", "webp", "svg", "bmp": return "图片 / 纹理文件"
		"wav", "mp3", "ogg": return "音频文件"
		"glb", "gltf", "obj", "fbx", "dae": return "3D 模型文件"
		"ttf", "otf", "woff", "woff2": return "字体文件"
		"json": return "JSON 数据文件"
		"cfg", "ini": return "配置文件"
		"import": return "导入配置文件"
		"godot": return "Godot 项目配置"
		"zip", "pck": return "打包文件"
	return ""

func suggest_bucket(text: String, kind: String) -> String:
	if kind != "code":
		return BUCKET_MAIN
	var clean := clean_text(text)
	if clean == "":
		return BUCKET_GODOT
	if grammar_exact.has(clean) or grammar_exact.has(clean.to_lower()):
		return BUCKET_GRAMMAR
	if godot_api_exact.has(clean) or godot_api_exact.has(clean.to_lower()):
		return BUCKET_GODOT
	if custom_api_exact.has(clean) or custom_api_exact.has(clean.to_lower()):
		return BUCKET_CUSTOM
	if _looks_engine_name(clean):
		return BUCKET_GODOT
	return BUCKET_CUSTOM

func _looks_engine_name(text: String) -> bool:
	if text == "":
		return false
	var first := text[0]
	if first >= "A" and first <= "Z":
		return true
	return text.contains(".")

func tmp_bucket(kind: String) -> String:
	return BUCKET_TMP_CODE if kind == "code" else BUCKET_TMP_OTHER

func bucket_label(bucket: String) -> String:
	match bucket:
		BUCKET_MAIN: return "主词库"
		BUCKET_GODOT: return "Godot API/类/属性"
		BUCKET_GRAMMAR: return "语法"
		BUCKET_CUSTOM: return "自定义 API/类/属性"
		BUCKET_TMP_CODE: return "待审·code"
		BUCKET_TMP_OTHER: return "待审·其他"
	return bucket

func add_tmp(text: String, zh: String, kind: String, context: String = "", provider: String = "online") -> String:
	var en := clean_text(text)
	var translation := _clean_translation(zh)
	if en == "" or translation == "":
		return ""
	if _find_official(en, kind) != "":
		return ""
	if en.length() > 200:
		return ""
	var bucket := tmp_bucket(kind)
	var target := tmp_code_exact if kind == "code" else tmp_other_exact
	var old := String(target.get(en, ""))
	if old != translation:
		target[en] = translation
		_save_dict("tmp/code_zh.json" if kind == "code" else "tmp/other_zh.json", target)
	_record_review(en, translation, kind, context, provider)
	return bucket

func _find_official(text: String, kind: String) -> String:
	var checks: Array = []
	if kind == "code":
		checks = [godot_api_exact, grammar_exact, custom_api_exact]
	else:
		checks = [main_exact]
	for d in checks:
		if (d as Dictionary).has(text) or (d as Dictionary).has(text.to_lower()):
			return String((d as Dictionary).get(text, (d as Dictionary).get(text.to_lower(), "")))
	return ""

func _clean_translation(raw: String) -> String:
	var t := raw.strip_edges()
	t = t.replace("&quot;", "\"")
	t = t.replace("&#39;", "'")
	t = t.replace("&amp;", "&")
	t = _tags.sub(t, "", true)
	return t.strip_edges()

func _review_key(text: String, kind: String) -> String:
	return kind.to_lower() + "|" + text.to_lower()

func _record_review(text: String, zh: String, kind: String, context: String, provider: String) -> void:
	var key := _review_key(text, kind)
	var now := Time.get_datetime_string_from_system()
	if not _review.has("entries") or typeof(_review["entries"]) != TYPE_DICTIONARY:
		_review = {"version": 1, "entries": {}}
	var entries: Dictionary = _review["entries"]
	var entry: Dictionary = entries.get(key, {})
	var was_applied := String(entry.get("status", "")) == "applied"
	if entry.is_empty() or was_applied:
		entry = {
			"en": text,
			"zh": zh,
			"kind": kind,
			"context": context,
			"bucket": suggest_bucket(text, kind),
			"suggested_bucket": suggest_bucket(text, kind),
			"status": "pending",
			"source": provider,
			"count": 1,
			"first_seen": now,
			"last_seen": now,
		}
	else:
		entry["zh"] = zh
		entry["context"] = context
		entry["source"] = provider
		entry["count"] = int(entry.get("count", 0)) + 1
		entry["last_seen"] = now
	entries[key] = entry
	_review["updated_at"] = now
	_save_review()

func _load_review() -> void:
	_review = {"version": 1, "entries": {}}
	_ensure_review_path()
	if _review_path == "" or not FileAccess.file_exists(_review_path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_review_path))
	if typeof(parsed) == TYPE_DICTIONARY:
		_review = parsed
		if typeof(_review.get("entries")) != TYPE_DICTIONARY:
			_review["entries"] = {}

func _ensure_review_path() -> void:
	if _review_path != "" and FileAccess.file_exists(_review_path):
		return
	DirAccess.make_dir_recursive_absolute(_review_path.get_base_dir())
	var f := FileAccess.open(_review_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": 1, "entries": {}}, "\t"))
		f.close()
	else:
		last_error = "无法创建审核文件：" + _review_path

func _save_review() -> void:
	_ensure_review_path()
	if _review_path == "":
		return
	var f := FileAccess.open(_review_path, FileAccess.WRITE)
	if f == null:
		last_error = "无法写入审核文件：" + _review_path
		return
	f.store_string(JSON.stringify(_review, "\t"))
	f.close()

func review_path() -> String:
	_ensure_review_path()
	return _review_path

func data_path() -> String:
	return _data_dir

func review_pending_count() -> int:
	var entries: Dictionary = _review.get("entries", {})
	var n := 0
	for k in entries.keys():
		if String((entries[k] as Dictionary).get("status", "")) == "pending":
			n += 1
	return n

func apply_review() -> int:
	_load_review()
	var entries: Dictionary = _review.get("entries", {})
	var applied := 0
	for k in entries.keys():
		var e: Dictionary = entries[k]
		var status := String(e.get("status", "pending"))
		var en := String(e.get("en", "")).strip_edges()
		var zh := _clean_translation(String(e.get("zh", "")))
		var bucket := String(e.get("bucket", e.get("suggested_bucket", BUCKET_MAIN)))
		if en == "":
			continue
		if status == "rejected":
			_remove_tmp(en)
			e["status"] = "rejected"
			e["reviewed_at"] = Time.get_datetime_string_from_system()
			continue
		if status != "approved":
			continue
		if zh == "" or not _valid_bucket(bucket):
			e["status"] = "error"
			e["error"] = "缺少译文或 bucket 非法"
			continue
		var target := _dict_for_bucket(bucket)
		if target == null:
			continue
		target[en] = zh
		_remove_tmp(en)
		e["status"] = "applied"
		e["applied_at"] = Time.get_datetime_string_from_system()
		applied += 1
	_save_dict("main_zh.json", main_exact)
	_save_dict("code/godot_api_zh.json", godot_api_exact)
	_save_dict("code/grammar_zh.json", grammar_exact)
	_save_dict("code/custom_api_zh.json", custom_api_exact)
	_save_dict("tmp/code_zh.json", tmp_code_exact)
	_save_dict("tmp/other_zh.json", tmp_other_exact)
	_save_review()
	reload()
	return applied

func _valid_bucket(bucket: String) -> bool:
	return bucket in [BUCKET_MAIN, BUCKET_GODOT, BUCKET_GRAMMAR, BUCKET_CUSTOM]

func _dict_for_bucket(bucket: String) -> Dictionary:
	match bucket:
		BUCKET_MAIN: return main_exact
		BUCKET_GODOT: return godot_api_exact
		BUCKET_GRAMMAR: return grammar_exact
		BUCKET_CUSTOM: return custom_api_exact
	return {}

func _remove_tmp(text: String) -> void:
	var changed := false
	if tmp_code_exact.has(text):
		tmp_code_exact.erase(text)
		changed = true
	if tmp_other_exact.has(text):
		tmp_other_exact.erase(text)
		changed = true
	if changed:
		_save_dict("tmp/code_zh.json", tmp_code_exact)
		_save_dict("tmp/other_zh.json", tmp_other_exact)

func _save_dict(relative: String, data: Dictionary) -> void:
	var path := _data_dir.path_join(relative)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		last_error = "无法写入词库：" + path
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func stats() -> Dictionary:
	return {
		"main": main_exact.size(),
		"godot_api": godot_api_exact.size(),
		"grammar": grammar_exact.size(),
		"custom_api": custom_api_exact.size(),
		"tmp_code": tmp_code_exact.size(),
		"tmp_other": tmp_other_exact.size(),
		"review_pending": review_pending_count(),
		"words": word_map.size(),
	}
