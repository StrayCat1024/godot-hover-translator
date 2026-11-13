@tool
extends Control
## Instant floating card that follows the mouse.
## It is deliberately a separate overlay: the native Godot tooltip is never touched.

var panel: PanelContainer
var word_label: Label
var badge_label: Label
var trans_label: Label
var footer_label: Label
var accent: ColorRect

var _font: SystemFont
var _last_mouse := Vector2(-10000, -10000)
var _current_word := ""
var _avoid_rects: Array[Rect2] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 4096
	z_as_relative = false
	visible = false

	_font = SystemFont.new()
	_font.font_names = PackedStringArray([
		"Microsoft YaHei UI",
		"Microsoft YaHei",
		"Noto Sans CJK SC",
		"Source Han Sans SC",
		"Segoe UI",
	])
	_font.font_weight = 400

	panel = PanelContainer.new()
	panel.name = "TranslationCard"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_stylebox_override("panel", _make_style())
	add_child(panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 11)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 5)
	margin.add_child(vbox)

	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	word_label = Label.new()
	word_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	word_label.add_theme_font_override("font", _font)
	word_label.add_theme_font_size_override("font_size", 19)
	word_label.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	word_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	word_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(word_label)

	badge_label = Label.new()
	badge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_label.add_theme_font_override("font", _font)
	badge_label.add_theme_font_size_override("font_size", 10)
	badge_label.add_theme_color_override("font_color", Color(0.45, 0.78, 1.0))
	badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(badge_label)

	var line := HSeparator.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 2)
	vbox.add_child(line)

	trans_label = Label.new()
	trans_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	trans_label.add_theme_font_override("font", _font)
	trans_label.add_theme_font_size_override("font_size", 15)
	trans_label.add_theme_color_override("font_color", Color(0.88, 0.90, 0.94))
	trans_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	trans_label.custom_minimum_size = Vector2(330, 0)
	trans_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(trans_label)

	footer_label = Label.new()
	footer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer_label.add_theme_font_override("font", _font)
	footer_label.add_theme_font_size_override("font_size", 10)
	footer_label.add_theme_color_override("font_color", Color(0.55, 0.59, 0.66))
	footer_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	footer_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vbox.add_child(footer_label)

	accent = ColorRect.new()
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent.color = Color(0.35, 0.70, 1.0, 0.95)
	accent.custom_minimum_size = Vector2(3, 0)
	add_child(accent)
	accent.visible = false

func _make_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.075, 0.085, 0.105, 0.98)
	sb.border_color = Color(0.28, 0.46, 0.68, 0.95)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.shadow_color = Color(0, 0, 0, 0.50)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 3)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	return sb

func show_result(result: Dictionary, mouse_pos: Vector2) -> void:
	var query := String(result.get("query", "")).strip_edges()
	var zh := String(result.get("zh", "")).strip_edges()
	var kind := String(result.get("kind", "ui"))
	var source := String(result.get("source", ""))
	var note := String(result.get("note", ""))
	var pending := bool(result.get("pending", false))
	var online_error := String(result.get("online_error", ""))
	var spoken := bool(result.get("spoken", true))

	_current_word = query
	word_label.text = _display_query(query)
	if zh == "" and pending:
		trans_label.text = "正在联网翻译…"
		trans_label.add_theme_color_override("font_color", Color(0.65, 0.78, 0.88))
	elif zh == "" and online_error != "":
		trans_label.text = "在线翻译失败：" + online_error
		trans_label.add_theme_color_override("font_color", Color(0.95, 0.62, 0.55))
	elif zh == "":
		trans_label.text = "词典暂未收录"
		trans_label.add_theme_color_override("font_color", Color(0.65, 0.67, 0.70))
	else:
		trans_label.text = zh
		trans_label.add_theme_color_override("font_color", Color(0.88, 0.90, 0.94))

	if pending and zh == "":
		badge_label.text = "联网"
		badge_label.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	elif source == "tmp":
		badge_label.text = "待审"
		badge_label.add_theme_color_override("font_color", Color(0.95, 0.72, 0.35))
	elif bool(result.get("staged", false)):
		badge_label.text = "在线·待审"
		badge_label.add_theme_color_override("font_color", Color(0.95, 0.72, 0.35))
	elif source == "online":
		badge_label.text = "在线"
		badge_label.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	elif source == "online_cache":
		badge_label.text = "在线·缓存"
		badge_label.add_theme_color_override("font_color", Color(0.50, 0.82, 0.70))
	elif kind == "code":
		badge_label.text = "代码"
		badge_label.add_theme_color_override("font_color", Color(0.52, 0.82, 1.0))
	elif kind == "file":
		badge_label.text = "文件"
		badge_label.add_theme_color_override("font_color", Color(0.95, 0.72, 0.35))
	elif source == "exact":
		badge_label.text = "引擎"
		badge_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	elif source == "native":
		badge_label.text = "引擎"
		badge_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	else:
		badge_label.text = "词典"
		badge_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))

	var footer := ""
	if pending:
		footer = "本地词典未命中 · 正在联网翻译"
	elif online_error != "":
		footer = "在线翻译失败 · 仍显示本地结果"
	elif source == "tmp":
		footer = "待审词条 · 审核后自动归入正式词库"
	elif bool(result.get("staged", false)):
		footer = "在线翻译 · 已加入待审词库"
	elif source == "online":
		footer = "在线翻译 · " + (note if note != "" else "MyMemory")
	elif source == "online_cache":
		footer = "在线翻译缓存 · 第二次起零延迟"
	elif kind == "code":
		footer = "代码 / API 术语"
	elif kind == "file":
		footer = "文件类型"
	elif source == "exact":
		footer = "Godot 官方中文译名"
	elif source == "native":
		footer = "编辑器原生中文提示"
	elif source == "compose":
		footer = "按词段组合翻译"
	else:
		footer = "本地词典"
	if note != "" and not pending and online_error == "" and source != "online" and source != "online_cache":
		footer += " · " + note
	if spoken:
		footer += " · 已朗读英文"
	else:
		footer += " · 语音未开启或不可用"
	footer_label.text = footer

	visible = true
	_layout(mouse_pos)

func set_avoid_rects(rects: Array[Rect2]) -> void:
	_avoid_rects = rects.duplicate()

func _layout(mouse_pos: Vector2) -> void:
	var vp := get_viewport_rect().size
	var max_width := 460.0
	trans_label.custom_minimum_size.x = min(max_width - 34.0, 390.0)
	panel.size = Vector2.ZERO
	panel.reset_size()
	var min_size := panel.get_combined_minimum_size()
	var w: float = clampf(min_size.x, 300.0, max_width)
	panel.size = Vector2(w, 0)
	trans_label.size = Vector2(w - 34.0, trans_label.size.y)
	panel.reset_size()
	var h: float = maxf(panel.size.y, 76.0)
	panel.size = Vector2(w, h)

	var gap := 16.0
	var candidates: Array[Vector2] = []
	if not _avoid_rects.is_empty():
		# Quadrant rule, with the pointer as the origin:
		#   native popup Q1 (right/down) -> card Q4 (right/up)
		#   native popup Q2 (left/down)  -> card Q3 (left/up)
		#   native popup Q3 (left/up)    -> card Q2 (left/down)
		#   native popup Q4 (right/up)   -> card Q1 (right/down)
		# The card shares the popup's near horizontal edge (left edge on the
		# right side, right edge on the left side) and sits just past the
		# popup's near vertical edge, so the two rectangles line up.
		var tip := _primary_tooltip()
		var side_gap := 8.0
		var center := tip.get_center()
		var on_right := center.x >= mouse_pos.x
		var tip_below := center.y >= mouse_pos.y
		var x := tip.position.x if on_right else tip.position.x + tip.size.x - w
		var y := tip.position.y - h - side_gap if tip_below else tip.position.y + tip.size.y + side_gap
		x = clampf(x, 8.0, maxf(8.0, vp.x - w - 8.0))
		y = clampf(y, 8.0, maxf(8.0, vp.y - h - 8.0))
		var chosen := Rect2(Vector2(x, y), Vector2(w, h))
		if _overlap_area(chosen) > 0.0:
			# No room past the opposite vertical edge; try the other side of
			# the popup, then a side-by-side slot, so the popup stays clear.
			var alt_y := tip.position.y + tip.size.y + side_gap if tip_below else tip.position.y - h - side_gap
			alt_y = clampf(alt_y, 8.0, maxf(8.0, vp.y - h - 8.0))
			var alt := Rect2(Vector2(x, alt_y), Vector2(w, h))
			if _overlap_area(alt) <= 0.0:
				chosen = alt
			else:
				var side_y := clampf(tip.position.y, 8.0, maxf(8.0, vp.y - h - 8.0))
				var left_rect := Rect2(Vector2(tip.position.x - w - side_gap, side_y), Vector2(w, h))
				var right_rect := Rect2(Vector2(tip.position.x + tip.size.x + side_gap, side_y), Vector2(w, h))
				var sides: Array[Rect2] = []
				if on_right:
					sides = [right_rect, left_rect]
				else:
					sides = [left_rect, right_rect]
				for r in sides:
					var rr := Rect2(Vector2(
						clampf(r.position.x, 8.0, maxf(8.0, vp.x - w - 8.0)),
						clampf(r.position.y, 8.0, maxf(8.0, vp.y - h - 8.0))
					), Vector2(w, h))
					if _overlap_area(rr) <= 0.0:
						chosen = rr
						break
		panel.position = chosen.position
		accent.position = chosen.position + Vector2(0, 7)
		accent.size = Vector2(3, h - 14)
		accent.visible = true
		return
	candidates.append_array([
		Vector2(mouse_pos.x + 20.0, mouse_pos.y + 22.0),
		Vector2(mouse_pos.x - w - gap, mouse_pos.y + 22.0),
		Vector2(mouse_pos.x + 20.0, mouse_pos.y - h - gap),
		Vector2(mouse_pos.x - w - gap, mouse_pos.y - h - gap),
		Vector2(12.0, vp.y - h - 12.0),
		Vector2(vp.x - w - 12.0, vp.y - h - 12.0),
		Vector2(vp.x - w - 12.0, 12.0),
		Vector2(12.0, 12.0),
	])
	var best := Vector2(12, 12)
	var best_score := INF
	for candidate in candidates:
		var pos := Vector2(
			clampf(candidate.x, 8.0, maxf(8.0, vp.x - w - 8.0)),
			clampf(candidate.y, 8.0, maxf(8.0, vp.y - h - 8.0))
		)
		var score := _overlap_area(Rect2(pos, Vector2(w, h)))
		if score < best_score:
			best_score = score
			best = pos
			if score <= 0.0:
				break
	panel.position = best
	accent.position = best + Vector2(0, 7)
	accent.size = Vector2(3, h - 14)
	accent.visible = true

func _primary_tooltip() -> Rect2:
	var best := _avoid_rects[0]
	for r in _avoid_rects:
		if r.get_area() > best.get_area():
			best = r
	return best

func _overlap_area(r: Rect2) -> float:
	var total := 0.0
	for avoid in _avoid_rects:
		var hit := r.intersection(avoid)
		if hit.size.x > 0.0 and hit.size.y > 0.0:
			total += hit.size.x * hit.size.y
	return total

func _display_query(q: String) -> String:
	var s := q.replace("\n", " ").strip_edges()
	if s.length() > 70:
		s = s.substr(0, 67) + "…"
	return s

func hide_card() -> void:
	visible = false
	accent.visible = false
	_current_word = ""

func move_card(mouse_pos: Vector2) -> void:
	if visible:
		_layout(mouse_pos)

func current_word() -> String:
	return _current_word
