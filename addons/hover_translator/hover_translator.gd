@tool
extends EditorPlugin
## Hover Translator for the Godot editor.
##
## Hover any English word or UI label: a separate card appears immediately
## (the native tooltip is never modified), showing a Chinese translation, and
## the English text is spoken through a persistent Windows SAPI helper.

const TranslatorScript = preload("res://addons/hover_translator/translator.gd")
const ProbeScript = preload("res://addons/hover_translator/probe.gd")
const OverlayScript = preload("res://addons/hover_translator/overlay.gd")
const TTSScript = preload("res://addons/hover_translator/tts.gd")
const OnlineScript = preload("res://addons/hover_translator/online.gd")
const VoiceScript = preload("res://addons/hover_translator/voice.gd")

var translator: RefCounted
var probe: RefCounted
var overlay: Control
var tts: Node
var online: Node
var voice: Node
var base: Control

var _last_key := ""
var _last_query := ""
var _last_kind := "ui"
var _last_context := ""
var _last_where := ""
var _last_result: Dictionary = {}
var _last_valid_mouse := Vector2.ZERO
var _tooltip_guard := 0.0
var _dock: VBoxContainer
var _status: Label
var _speech_status: Label
var _online_status: Label
var _current_word: Label
var _current_zh: Label
var _history: ItemList
var _history_words: Array[String] = []
var _history_zh: Array[String] = []
var _speak_check: CheckBox
var _card_check: CheckBox
var _online_check: CheckBox
var _rate_spin: SpinBox
var _voice_edit: LineEdit
var _status_refresh := 0.0
var _online_token := ""
var _online_wait_id := 0
var _review_watch := 0.0
var _review_mtime := -1

func _enter_tree() -> void:
	print("[HoverTranslator] loaded")
	_define_settings()
	translator = TranslatorScript.new()
	base = EditorInterface.get_base_control()
	probe = ProbeScript.new(base, translator)

	overlay = OverlayScript.new()
	overlay.name = "HoverTranslatorOverlay"
	base.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	tts = TTSScript.new()
	tts.name = "HoverTranslatorTTS"
	add_child(tts)
	if not bool(ProjectSettings.get_setting("hover_translator/online_voice", true)):
		tts.start()

	online = OnlineScript.new()
	online.name = "HoverTranslatorOnline"
	add_child(online)
	online.resolved.connect(_on_online_resolved)
	online.failed.connect(_on_online_failed)
	_configure_online()

	voice = VoiceScript.new()
	voice.name = "HoverTranslatorOnlineVoice"
	add_child(voice)
	_configure_voice()

	_build_dock()
	set_process(true)

func _exit_tree() -> void:
	set_process(false)
	if _dock:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
	if tts:
		tts.queue_free()
		tts = null
	if online:
		online.queue_free()
		online = null
	if voice:
		voice.queue_free()
		voice = null
	if overlay:
		overlay.queue_free()
		overlay = null
	probe = null
	translator = null

func _process(delta: float) -> void:
	if overlay == null or not is_instance_valid(overlay):
		return
	_status_refresh -= delta
	if _status_refresh <= 0.0:
		_status_refresh = 1.0
		_refresh_status()
	_review_watch -= delta
	if _review_watch <= 0.0:
		_review_watch = 2.0
		_maybe_auto_apply_review()
	if not bool(ProjectSettings.get_setting("hover_translator/enabled", true)):
		overlay.hide_card()
		_last_key = ""
		return
	if probe == null:
		return
	probe.tick(delta)

	if base == null or not is_instance_valid(base):
		return
	var raw_mouse := base.get_viewport().get_mouse_position()
	if raw_mouse != Vector2.ZERO:
		_last_valid_mouse = raw_mouse
	elif _last_valid_mouse == Vector2.ZERO:
		var screen_mouse := DisplayServer.mouse_get_position()
		var mapped := base.get_global_transform_with_canvas().affine_inverse() * Vector2(screen_mouse)
		if mapped != Vector2.ZERO:
			_last_valid_mouse = mapped
	var mouse_global := raw_mouse if raw_mouse != Vector2.ZERO else _last_valid_mouse
	_tooltip_guard -= delta
	if _tooltip_guard <= 0.0:
		_tooltip_guard = 0.05
		_update_tooltip_avoidance(mouse_global)
	var mouse_local := base.get_global_transform().affine_inverse() * mouse_global
	var target: Dictionary = probe.find(mouse_global)
	if target.is_empty():
		var tooltip_rects: Array[Rect2] = probe.native_tooltip_rects(mouse_global)
		if not tooltip_rects.is_empty() and not _last_result.is_empty():
			# The native help popup temporarily owns the pointer. Keep the
			# last card visible and just move it out of the popup's way.
			overlay.set_avoid_rects(tooltip_rects)
			if bool(ProjectSettings.get_setting("hover_translator/follow_mouse", true)):
				overlay.move_card(mouse_local)
			return
		overlay.hide_card()
		_last_key = ""
		_last_result = {}
		return

	var text := String(target.get("text", ""))
	var kind := String(target.get("kind", "ui"))
	var key := text + "|" + kind
	if key == _last_key:
		# Keep the card glued to the cursor while it stays on the same word.
		if bool(ProjectSettings.get_setting("hover_translator/follow_mouse", true)):
			overlay.move_card(mouse_local)
		return

	_last_key = key
	_last_kind = kind
	_last_context = String(target.get("context", ""))
	_last_where = String(target.get("where", ""))
	var result: Dictionary = translator.lookup(text, kind)
	if target.has("zh"):
		result["zh"] = String(target.get("zh", ""))
		result["source"] = "native"
	_last_query = String(result.get("query", text))

	var wants_online := _needs_online(result) and bool(ProjectSettings.get_setting("hover_translator/online_fallback", true))
	if wants_online and online != null:
		var cached_zh: String = online.get_cached(text, kind)
		if cached_zh != "":
			result["zh"] = cached_zh
			result["source"] = "online_cache"
			result["note"] = "在线翻译缓存"
			var cached_bucket: String = translator.add_tmp(text, cached_zh, kind, _last_context, "cache")
			if cached_bucket != "":
				result["staged"] = true
				result["bucket"] = cached_bucket
				result["note"] = "在线翻译缓存（待审）"
			wants_online = false
		else:
			result["pending"] = true
			if String(result.get("zh", "")) == "":
				result["zh"] = "正在联网翻译…"
			if String(result.get("source", "")) == "compose":
				result["note"] = "本地组合释义，正在联网校对"
			else:
				result["note"] = "本地词典未收录，正在联网"

	var say: String = translator.speech_text(text)
	var spoke := false
	if bool(ProjectSettings.get_setting("hover_translator/speak", true)) and say != "":
		spoke = _speak_english(say)
	result["spoken"] = spoke
	_last_result = result.duplicate(true)

	if bool(ProjectSettings.get_setting("hover_translator/show_card", true)):
		overlay.set_avoid_rects(probe.native_tooltip_rects(mouse_global))
		overlay.show_result(result, mouse_local)
	else:
		overlay.hide_card()
	_update_dock_result(result)
	_add_history(result)
	if wants_online and online != null:
		_schedule_online(text, kind, String(result.get("query", text)), _last_context)

func _needs_online(result: Dictionary) -> bool:
	if String(result.get("zh", "")) == "":
		return true
	if String(result.get("source", "")) == "compose" and String(result.get("note", "")) == "组合释义":
		return true
	return false

func _schedule_online(text: String, kind: String, query: String, context: String = "") -> void:
	_online_token = text + "|" + kind
	_online_wait_id += 1
	var my_id := _online_wait_id
	await get_tree().create_timer(0.25).timeout
	if my_id != _online_wait_id or _online_token != _last_key:
		return
	var q := query
	if kind == "code" and translator.is_identifier(text):
		q = translator.speech_text(text)
	if q.strip_edges() == "":
		return
	online.request(text, kind, q, context)

func _on_online_resolved(query: String, kind: String, zh: String, provider: String, cached: bool, context: String) -> void:
	var stored_bucket: String = translator.add_tmp(query, zh, kind, context, provider)
	if query.strip_edges().to_lower() != _last_query.strip_edges().to_lower() or kind != _last_kind:
		return
	var result: Dictionary = translator.lookup(query, kind)
	result["zh"] = zh
	result["source"] = "online_cache" if cached else "online"
	result["note"] = provider + ("（缓存）" if cached else "")
	if stored_bucket != "":
		result["staged"] = true
		result["bucket"] = stored_bucket
		result["note"] += " · 已加入待审词库"
	result["spoken"] = bool(_last_result.get("spoken", false))
	_last_result = result.duplicate(true)
	if overlay != null and overlay.visible and base != null:
		var mouse_global := base.get_viewport().get_mouse_position()
		var mouse_local := base.get_global_transform().affine_inverse() * mouse_global
		overlay.show_result(result, mouse_local)
	_update_dock_result(result)
	_update_history_result(result)

func _on_online_failed(query: String, kind: String, message: String) -> void:
	if query != _last_query or kind != _last_kind:
		return
	var result: Dictionary = _last_result.duplicate(true)
	result.erase("pending")
	result["online_error"] = message
	if String(result.get("zh", "")) == "正在联网翻译…":
		result["zh"] = ""
	result["spoken"] = bool(_last_result.get("spoken", false))
	_last_result = result.duplicate(true)
	if overlay != null and overlay.visible and base != null:
		var mouse_global := base.get_viewport().get_mouse_position()
		var mouse_local := base.get_global_transform().affine_inverse() * mouse_global
		overlay.show_result(result, mouse_local)
	_update_dock_result(result)

func _configure_online() -> void:
	if online == null:
		return
	online.enabled = bool(ProjectSettings.get_setting("hover_translator/online_fallback", true))
	online.endpoint = String(ProjectSettings.get_setting(
		"hover_translator/online_url",
		"https://api.mymemory.translated.net/get?q={query}&langpair=en%7Czh-CN"
	))
	online.timeout = float(ProjectSettings.get_setting("hover_translator/online_timeout", 8))

func _configure_voice() -> void:
	if voice == null:
		return
	voice.enabled = bool(ProjectSettings.get_setting("hover_translator/online_voice", true))
	voice.voice_name = String(ProjectSettings.get_setting("hover_translator/online_voice_name", "en-US-GuyNeural"))
	voice.timeout = float(ProjectSettings.get_setting("hover_translator/online_timeout", 8))
	var vol := clampi(int(ProjectSettings.get_setting("hover_translator/volume", 100)), 1, 100)
	voice.volume_db = linear_to_db(float(vol) / 100.0)

func _speak_english(text: String) -> bool:
	var say := text.strip_edges()
	if say == "":
		return false
	# Prefer the external Edge voice so every word uses the same male voice.
	if voice != null and bool(voice.enabled):
		if bool(voice.speak(say)):
			return true
	if tts != null and tts.is_ready():
		if bool(tts.speak(say)):
			return true
	return false

func _refresh_status() -> void:
	if _status != null:
		if voice != null and bool(voice.enabled):
			_status.text = "朗读：Edge 在线语音（外部，统一男声）"
		elif tts != null:
			_status.text = tts.status()
	if _speech_status != null and voice != null:
		_speech_status.text = voice.status_text()
	if _online_status != null and online != null:
		_online_status.text = online.status_text()

func _define_settings() -> void:
	_add_bool("hover_translator/enabled", true, "启用悬停翻译")
	_add_bool("hover_translator/speak", true, "悬停时朗读英文")
	_add_bool("hover_translator/follow_mouse", true, "浮窗跟随鼠标")
	_add_bool("hover_translator/show_card", true, "显示翻译浮窗")
	_add_bool("hover_translator/online_fallback", true, "本地词典未命中时联网翻译")
	_add_bool("hover_translator/online_voice", true, "系统语音不可用时使用在线语音")
	_add_bool("hover_translator/auto_apply_review", true, "审核文件出现 approved 时自动导入词库")
	_add_int_range("hover_translator/rate", 0, -10, 10, "语音语速（-10 到 10）")
	_add_int_range("hover_translator/volume", 100, 0, 100, "语音音量（0 到 100）")
	_add_int_range("hover_translator/online_timeout", 8, 3, 30, "在线翻译超时（秒）")
	_add_string("hover_translator/voice", "Microsoft Zira Desktop", "英文语音名称")
	_add_string("hover_translator/online_url", "https://api.mymemory.translated.net/get?q={query}&langpair=en%7Czh-CN", "在线翻译接口模板（{query} 为英文）")
	_add_string("hover_translator/online_voice_name", "en-US-GuyNeural", "Edge 在线语音名称（男声 en-US-GuyNeural）")

func _add_bool(key: String, value: bool, label: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
		ProjectSettings.add_property_info({"name": key, "type": TYPE_BOOL, "hint_string": label})

func _add_int_range(key: String, value: int, min_value: int, max_value: int, label: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
		ProjectSettings.add_property_info({
			"name": key,
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "%d,%d,1,%s" % [min_value, max_value, label],
		})

func _add_string(key: String, value: String, label: String) -> void:
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, value)
		ProjectSettings.add_property_info({"name": key, "type": TYPE_STRING, "hint_string": label})

func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "HoverTranslatorPanel"
	_dock.add_theme_constant_override("separation", 6)

	var margin := MarginContainer.new()
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	_dock.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 5)
	margin.add_child(root)

	var title := Label.new()
	title.text = "悬停翻译  ·  鼠标划过英文立即显示中文并朗读"
	title.add_theme_font_size_override("font_size", 14)
	root.add_child(title)

	_status = Label.new()
	_status.text = tts.status() if tts else "语音未启动"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", Color(0.65, 0.72, 0.82))
	root.add_child(_status)

	_speech_status = Label.new()
	_speech_status.text = voice.status_text() if voice else "在线语音：未启用"
	_speech_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_speech_status.add_theme_font_size_override("font_size", 10)
	_speech_status.add_theme_color_override("font_color", Color(0.55, 0.68, 0.72))
	root.add_child(_speech_status)

	_online_status = Label.new()
	_online_status.text = online.status_text() if online else "在线兜底：未启用"
	_online_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_online_status.add_theme_font_size_override("font_size", 10)
	_online_status.add_theme_color_override("font_color", Color(0.55, 0.68, 0.72))
	root.add_child(_online_status)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 12)
	root.add_child(row1)

	_speak_check = CheckBox.new()
	_speak_check.text = "朗读英文"
	_speak_check.button_pressed = bool(ProjectSettings.get_setting("hover_translator/speak", true))
	_speak_check.toggled.connect(_on_speak_toggled)
	row1.add_child(_speak_check)

	_card_check = CheckBox.new()
	_card_check.text = "显示浮窗"
	_card_check.button_pressed = bool(ProjectSettings.get_setting("hover_translator/show_card", true))
	_card_check.toggled.connect(_on_card_toggled)
	row1.add_child(_card_check)

	_online_check = CheckBox.new()
	_online_check.text = "在线兜底"
	_online_check.button_pressed = bool(ProjectSettings.get_setting("hover_translator/online_fallback", true))
	_online_check.toggled.connect(_on_online_toggled)
	row1.add_child(_online_check)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	root.add_child(row2)

	var rate_label := Label.new()
	rate_label.text = "语速"
	row2.add_child(rate_label)

	_rate_spin = SpinBox.new()
	_rate_spin.min_value = -10
	_rate_spin.max_value = 10
	_rate_spin.step = 1
	_rate_spin.value = int(ProjectSettings.get_setting("hover_translator/rate", 0))
	_rate_spin.custom_minimum_size.x = 70
	_rate_spin.value_changed.connect(_on_rate_changed)
	row2.add_child(_rate_spin)

	var voice_label := Label.new()
	voice_label.text = "英文语音"
	row2.add_child(voice_label)

	_voice_edit = LineEdit.new()
	_voice_edit.text = String(ProjectSettings.get_setting("hover_translator/voice", "Microsoft Zira Desktop"))
	_voice_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_edit.placeholder_text = "例如 Microsoft Zira Desktop"
	row2.add_child(_voice_edit)

	var apply_voice := Button.new()
	apply_voice.text = "应用并重启语音"
	apply_voice.pressed.connect(_on_apply_voice)
	row2.add_child(apply_voice)

	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 8)
	root.add_child(row3)

	var test_btn := Button.new()
	test_btn.text = "测试语音"
	test_btn.pressed.connect(_on_test)
	row3.add_child(test_btn)

	var restart_tts_btn := Button.new()
	restart_tts_btn.text = "重启语音"
	restart_tts_btn.pressed.connect(_on_restart_tts)
	row3.add_child(restart_tts_btn)

	var reload_btn := Button.new()
	reload_btn.text = "重新加载词典"
	reload_btn.pressed.connect(_on_reload)
	row3.add_child(reload_btn)

	var clear_cache_btn := Button.new()
	clear_cache_btn.text = "清空在线缓存"
	clear_cache_btn.pressed.connect(_on_clear_online_cache)
	row3.add_child(clear_cache_btn)

	var open_review_btn := Button.new()
	open_review_btn.text = "打开审核文件"
	open_review_btn.pressed.connect(_on_open_review)
	row3.add_child(open_review_btn)

	var open_dict_btn := Button.new()
	open_dict_btn.text = "打开词库目录"
	open_dict_btn.pressed.connect(_on_open_dicts)
	row3.add_child(open_dict_btn)

	var import_review_btn := Button.new()
	import_review_btn.text = "导入审核结果"
	import_review_btn.pressed.connect(_on_import_review)
	row3.add_child(import_review_btn)

	var stats: Dictionary = translator.stats()
	var stats_label := Label.new()
	stats_label.text = "主 %d · Godot %d · 语法 %d · 自定义 %d\n待审 code %d · 其他 %d · 待导入 %d" % [
		stats.main, stats.godot_api, stats.grammar, stats.custom_api,
		stats.tmp_code, stats.tmp_other, stats.review_pending,
	]
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.add_theme_font_size_override("font_size", 10)
	stats_label.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
	root.add_child(stats_label)

	_current_word = Label.new()
	_current_word.text = "当前：—"
	_current_word.add_theme_font_size_override("font_size", 13)
	root.add_child(_current_word)

	_current_zh = Label.new()
	_current_zh.text = "把鼠标移到英文上试试。"
	_current_zh.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_current_zh.add_theme_font_size_override("font_size", 15)
	_current_zh.add_theme_color_override("font_color", Color(0.72, 0.86, 1.0))
	root.add_child(_current_zh)

	var hist_label := Label.new()
	hist_label.text = "最近查过"
	hist_label.add_theme_font_size_override("font_size", 11)
	hist_label.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
	root.add_child(hist_label)

	_history = ItemList.new()
	_history.custom_minimum_size = Vector2(0, 90)
	_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history.item_selected.connect(_on_history_selected)
	root.add_child(_history)

	add_control_to_bottom_panel(_dock, "划词翻译")

func _on_speak_toggled(on: bool) -> void:
	ProjectSettings.set_setting("hover_translator/speak", on)
	ProjectSettings.save()

func _update_tooltip_avoidance(mouse_global: Vector2) -> void:
	if overlay == null or probe == null or base == null or not is_instance_valid(base):
		return
	var rects: Array[Rect2] = probe.native_tooltip_rects(mouse_global)
	overlay.set_avoid_rects(rects)
	if overlay.visible and bool(ProjectSettings.get_setting("hover_translator/follow_mouse", true)):
		var mouse_local := base.get_global_transform().affine_inverse() * mouse_global
		overlay.move_card(mouse_local)

func _on_card_toggled(on: bool) -> void:
	ProjectSettings.set_setting("hover_translator/show_card", on)
	ProjectSettings.save()
	if not on and overlay:
		overlay.hide_card()

func _maybe_auto_apply_review() -> void:
	if translator == null or not bool(ProjectSettings.get_setting("hover_translator/auto_apply_review", true)):
		return
	var path: String = translator.review_path()
	var mtime := FileAccess.get_modified_time(path)
	if mtime == 0 or mtime == _review_mtime:
		return
	_review_mtime = mtime
	var n: int = int(translator.apply_review())
	_review_mtime = FileAccess.get_modified_time(path)
	if n > 0:
		_current_zh.text = "已自动导入 %d 条审核词条。" % n
		_refresh_status()

func _on_online_toggled(on: bool) -> void:
	ProjectSettings.set_setting("hover_translator/online_fallback", on)
	ProjectSettings.save()
	if online:
		online.enabled = on
	_refresh_status()

func _on_rate_changed(v: float) -> void:
	ProjectSettings.set_setting("hover_translator/rate", int(v))
	ProjectSettings.save()
	if tts:
		tts.start()

func _on_apply_voice() -> void:
	ProjectSettings.set_setting("hover_translator/voice", _voice_edit.text.strip_edges())
	ProjectSettings.save()
	if tts:
		tts.start()
	_speak_english("Voice ready")
	_refresh_status()

func _on_restart_tts() -> void:
	if tts:
		tts.restart()
	_speak_english("Hello, this is a voice test.")
	_refresh_status()

func _on_reload() -> void:
	translator = TranslatorScript.new()
	probe = ProbeScript.new(base, translator)
	var st: Dictionary = translator.stats()
	_current_zh.text = "词典已重新加载：主 %d / Godot %d / 语法 %d / 自定义 %d / 待审 code %d / 其他 %d" % [
		st.main, st.godot_api, st.grammar, st.custom_api, st.tmp_code, st.tmp_other,
	]

func _on_clear_online_cache() -> void:
	if online:
		online.clear_cache()
	_refresh_status()

func _on_open_review() -> void:
	var path: String = translator.review_path()
	OS.shell_open(path)
	_current_zh.text = "审核文件：" + path

func _on_open_dicts() -> void:
	var path: String = translator.data_path()
	OS.shell_open(path)
	_current_zh.text = "词库目录：" + path

func _on_import_review() -> void:
	var n: int = int(translator.apply_review())
	translator = TranslatorScript.new()
	probe = ProbeScript.new(base, translator)
	_current_zh.text = "已导入 %d 条审核词条。" % n
	if translator.last_error != "":
		_current_zh.text += "\n" + translator.last_error
	_refresh_status()

func _on_test() -> void:
	var ok := _speak_english("Hello, this is the hover translator voice test.")
	if not ok:
		_status.text = "语音不可用：" + tts.status()
	_refresh_status()

func _update_dock_result(result: Dictionary) -> void:
	if _current_word == null:
		return
	var q := String(result.get("query", ""))
	var zh := String(result.get("zh", ""))
	if zh == "":
		if bool(result.get("pending", false)):
			zh = "正在联网翻译…"
		elif String(result.get("online_error", "")) != "":
			zh = "在线翻译失败：" + String(result.get("online_error", ""))
		else:
			zh = "词典暂未收录"
	_current_word.text = "当前：" + q
	_current_zh.text = zh
	if not bool(ProjectSettings.get_setting("hover_translator/show_card", true)) and overlay:
		overlay.hide_card()

func _add_history(result: Dictionary) -> void:
	var q := String(result.get("query", ""))
	var zh := String(result.get("zh", ""))
	if q == "" or _history == null:
		return
	if _history_words.size() > 0 and _history_words[_history_words.size() - 1] == q:
		_update_history_result(result)
		return
	_history_words.append(q)
	_history_zh.append(zh)
	while _history_words.size() > 30:
		_history_words.pop_front()
		_history_zh.pop_front()
	_history.clear()
	for i in _history_words.size():
		_history.add_item(_history_words[i] + "    —    " + _history_zh[i])

func _update_history_result(result: Dictionary) -> void:
	if _history == null:
		return
	var q := String(result.get("query", ""))
	if q == "":
		return
	var zh := String(result.get("zh", ""))
	for i in range(_history_words.size() - 1, -1, -1):
		if _history_words[i] == q:
			_history_zh[i] = zh
			_history.set_item_text(i, q + "    —    " + zh)
			return

func _on_history_selected(index: int) -> void:
	if index < 0 or index >= _history_words.size():
		return
	var q := _history_words[index]
	var kind := "code" if translator.is_identifier(q) else "ui"
	var result: Dictionary = translator.lookup(q, kind)
	_update_dock_result(result)
	if tts:
		_speak_english(translator.speech_text(q))
	if _needs_online(result) and bool(ProjectSettings.get_setting("hover_translator/online_fallback", true)) and online != null:
		_last_query = String(result.get("query", q))
		_last_kind = kind
		online.request(q, kind, String(result.get("query", q)))

func _input(event: InputEvent) -> void:
	# Shift-hover is a quick way to repeat the pronunciation without moving away.
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.shift_pressed and _last_query != "":
			var now := Time.get_ticks_msec()
			if now - int(_last_spoken_ms) > 450:
				_last_spoken_ms = now
				_speak_english(translator.speech_text(_last_query))

var _last_spoken_ms := 0
