@tool
extends RefCounted
## Finds the English text under the mouse across the editor UI, including
## embedded popup windows, trees, tabs and code editors.

var _base: Control
var _translator: RefCounted
var _windows: Array[Window] = []
var _rebuild := 0.0

func _init(base: Control, translator: RefCounted = null) -> void:
	_base = base
	_translator = translator
	_rebuild_windows()

func tick(delta: float) -> void:
	_rebuild -= delta
	if _rebuild <= 0.0:
		_rebuild = 0.35
		_rebuild_windows()

func find(mouse_pos: Vector2) -> Dictionary:
	if _base == null or not is_instance_valid(_base):
		return {}
	if _windows.is_empty():
		_rebuild_windows()
	for i in range(_windows.size() - 1, -1, -1):
		var w: Window = _windows[i]
		if not is_instance_valid(w) or not w.visible:
			continue
		if w is PopupMenu:
			var pop := _popup_target(w as PopupMenu, mouse_pos)
			if not pop.is_empty():
				return _clean_target(pop)
		if _is_tooltip_window(w):
			# Keep the native tooltip visible, but do not let it steal the
			# hover target from the editor control underneath.
			continue
		var c: Control = w.gui_get_hovered_control()
		if c and c.is_visible_in_tree():
			var target := _from_control(c, mouse_pos)
			if not target.is_empty():
				return _clean_target(target)
	return {}

func _clean_target(target: Dictionary) -> Dictionary:
	var t := _clean_target_text(String(target.get("text", "")))
	if t == "":
		return {}
	target["text"] = t
	return target

func _clean_target_text(t: String) -> String:
	var s := t.strip_edges()
	if not s.contains("|"):
		return s
	# The native help popup builds its title as "class|Node|"; never feed
	# those internal separators to the dictionary/online translation.
	var parts := s.split("|", false)
	for i in range(parts.size() - 1, -1, -1):
		var part := String(parts[i]).strip_edges()
		if part != "" and _has_letters(part):
			return part
	return s

func native_tooltip_rects(mouse_pos: Vector2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	if _windows.is_empty():
		_rebuild_windows()
	for w in _windows:
		if not is_instance_valid(w) or not w.visible:
			continue
		if not _is_tooltip_window(w):
			continue
		var r := _window_rect(w, mouse_pos)
		if _is_help_window(w) or _rect_distance(r, mouse_pos) <= 240.0:
			out.append(r)
	return out

func _window_rect(w: Window, mouse_pos: Vector2) -> Rect2:
	# Embedded subwindows use parent-relative coordinates, native popups use
	# screen coordinates. Pick whichever rectangle sits next to the pointer.
	var r := Rect2(Vector2(w.position), Vector2(w.size))
	var screen_pos := Vector2(DisplayServer.window_get_position())
	var alt := Rect2(Vector2(w.position) - screen_pos, Vector2(w.size))
	return alt if _rect_distance(alt, mouse_pos) < _rect_distance(r, mouse_pos) else r

func _rect_distance(r: Rect2, p: Vector2) -> float:
	var q := Vector2(
		clampf(p.x, r.position.x, r.position.x + r.size.x),
		clampf(p.y, r.position.y, r.position.y + r.size.y)
	)
	return q.distance_to(p)

func _is_help_window(w: Window) -> bool:
	var cn := w.get_class()
	return cn == "EditorHelpBitTooltip" or cn.contains("Tooltip") or cn.contains("HelpBit")

func _is_tooltip_window(w: Window) -> bool:
	if w is PopupMenu or w is AcceptDialog or w is ConfirmationDialog or w is FileDialog:
		return false
	if _is_help_window(w):
		return true
	if w is PopupPanel:
		return true
	if w.borderless and w.size.x > 0 and w.size.y > 0 and w.size.x <= 1400.0 and w.size.y <= 1000.0:
		return true
	return false

func _rebuild_windows() -> void:
	_windows.clear()
	var root := _base.get_tree().root if _base else null
	if root:
		_collect_windows(root)

func _collect_windows(node: Node) -> void:
	if node is Window and node.visible:
		_windows.append(node as Window)
	for child in node.get_children():
		_collect_windows(child)

func _popup_target(pop: PopupMenu, mouse_pos: Vector2) -> Dictionary:
	var rect := Rect2(Vector2(pop.position), Vector2(pop.size))
	if not rect.has_point(mouse_pos):
		return {}
	var idx := -1
	if pop.has_method("get_item_at_position"):
		idx = int(pop.call("get_item_at_position", mouse_pos - rect.position))
	if idx < 0:
		idx = pop.get_focused_item()
	if idx >= 0 and idx < pop.item_count and not pop.is_item_separator(idx):
		var t := pop.get_item_text(idx)
		if _has_letters(t):
			return {"text": t, "kind": "ui"}
	return {}

func _from_control(c: Control, mouse_pos: Vector2) -> Dictionary:
	if c is TextEdit:
		return _code_target(c as TextEdit, mouse_pos)
	if c is Tree:
		var tr := _tree_target(c as Tree, mouse_pos)
		if not tr.is_empty():
			tr["control"] = c
		return tr
	if c is ItemList:
		var il := _item_list_target(c as ItemList, mouse_pos)
		if not il.is_empty():
			il["control"] = c
		return il
	if c is TabBar:
		var tb := _tab_target(c as TabBar, mouse_pos)
		if not tb.is_empty():
			tb["control"] = c
		return tb

	var node: Node = c
	for depth in 6:
		if node == null or not (node is Control):
			break
		var ctrl := node as Control
		var prop := _property_target(ctrl)
		if not prop.is_empty():
			prop["control"] = c
			return prop
		var section := _section_target(ctrl)
		if not section.is_empty():
			section["control"] = c
			return section
		var direct := _direct_text(ctrl)
		if direct != "":
			return {"text": direct, "kind": "ui", "control": c}
		var child_text := _child_text_at(ctrl, mouse_pos, 0)
		if child_text != "":
			return {"text": child_text, "kind": "ui", "control": c}
		if ctrl.tooltip_text.strip_edges() != "":
			var tip := ctrl.tooltip_text.strip_edges()
			if _has_letters(tip):
				return {"text": tip, "kind": "ui", "control": c}
			if _has_cjk(tip):
				var en: String = _reverse(tip)
				if en != "":
					return {"text": en, "zh": tip, "kind": "ui", "control": c}
		node = ctrl.get_parent()
	return {}

func _direct_text(c: Control) -> String:
	var t := ""
	if c is Label:
		t = (c as Label).text
	elif c is RichTextLabel:
		t = (c as RichTextLabel).get_parsed_text()
	elif c is Button:
		t = (c as Button).text
	elif c is LineEdit:
		t = (c as LineEdit).text
	elif c is MenuBar:
		t = ""
	if t.strip_edges() == "" or not _has_letters(t):
		return ""
	return t

func _child_text_at(c: Control, mouse_pos: Vector2, depth: int) -> String:
	if depth > 2:
		return ""
	var best := ""
	var best_area := INF
	for child in c.get_children():
		if not (child is Control):
			continue
		var cc := child as Control
		if not cc.is_visible_in_tree():
			continue
		var r := cc.get_global_rect()
		if not r.has_point(mouse_pos):
			continue
		var t := _direct_text(cc)
		if t != "" and r.get_area() < best_area:
			best = t
			best_area = r.get_area()
		var nested := _child_text_at(cc, mouse_pos, depth + 1)
		if nested != "" and r.get_area() < best_area:
			best = nested
			best_area = r.get_area()
	return best

func _code_target(te: TextEdit, _mouse_pos: Vector2) -> Dictionary:
	var local := te.get_local_mouse_position()
	var lc := te.get_line_column_at_pos(Vector2i(local))
	var line := lc.x
	var col := lc.y
	if line < 0 or line >= te.get_line_count():
		return {}
	var line_text := te.get_line(line)
	var word := _word_in_line(line_text, col)
	if word == "":
		word = te.get_word_at_pos(local)
	if word.strip_edges() == "" or not _has_letters(word):
		return {}
	return {"text": word, "kind": "code", "context": line_text.strip_edges(), "where": "script"}

func _word_in_line(line: String, col: int) -> String:
	var n := line.length()
	if n == 0:
		return ""
	var i := clampi(col, 0, n)
	var start := i
	while start > 0 and _is_ident(line[start - 1]):
		start -= 1
	var end := i
	while end < n and _is_ident(line[end]):
		end += 1
	if start == end:
		return ""
	return line.substr(start, end - start)

func _is_ident(ch: String) -> bool:
	if ch == "_":
		return true
	var c := ch.unicode_at(0)
	return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)

func _tree_target(tree: Tree, _mouse_pos: Vector2) -> Dictionary:
	var local := tree.get_local_mouse_position()
	var item := tree.get_item_at_position(local)
	var col := tree.get_column_at_position(local)
	if item:
		if col >= 0 and col < tree.columns:
			var t := item.get_text(col)
			if t.strip_edges() != "" and _has_letters(t):
				return {"text": t, "kind": "code", "context": "tree column %d" % col, "where": "tree"}
		for i in tree.columns:
			var t2 := item.get_text(i)
			if t2.strip_edges() != "" and _has_letters(t2):
				return {"text": t2, "kind": "code", "context": "tree column %d" % i, "where": "tree"}
	if col >= 0 and col < tree.columns:
		var title := tree.get_column_title(col)
		if title.strip_edges() != "" and _has_letters(title):
			return {"text": title, "kind": "ui", "context": "tree header", "where": "tree"}
	return {}

func _item_list_target(list: ItemList, _mouse_pos: Vector2) -> Dictionary:
	var local := list.get_local_mouse_position()
	var idx: int = list.get_item_at_position(local)
	if idx >= 0:
		var t := list.get_item_text(idx)
		if t.strip_edges() != "" and _has_letters(t):
			return {"text": t, "kind": "ui"}
	return {}

func _tab_target(tab: TabBar, _mouse_pos: Vector2) -> Dictionary:
	var local := tab.get_local_mouse_position()
	var idx := -1
	if tab.has_method("get_tab_idx_at_point"):
		idx = int(tab.call("get_tab_idx_at_point", local))
	elif tab.has_method("get_tab_rect"):
		for i in tab.get_tab_count():
			if tab.get_tab_rect(i).has_point(local):
				idx = i
				break
	if idx >= 0:
		var t := tab.get_tab_title(idx)
		if t.strip_edges() != "" and _has_letters(t):
			return {"text": t, "kind": "ui"}
	return {}

func _property_target(c: Control) -> Dictionary:
	var node: Node = c
	for i in 5:
		if node == null:
			break
		if node.has_method("get_edited_property"):
			var label := ""
			if node.has_method("get_label"):
				label = String(node.call("get_label")).strip_edges()
			var prop := String(node.call("get_edited_property")).strip_edges()
			if _has_letters(label):
				return {"text": label, "kind": "code", "context": "inspector property: " + prop, "where": "inspector"}
			if prop != "":
				return {"text": _property_display(prop), "kind": "code", "context": "inspector property: " + prop, "where": "inspector"}
		node = node.get_parent()
	return {}

func _section_target(c: Control) -> Dictionary:
	var node: Node = c
	for i in 4:
		if node == null:
			break
		if node.get_class().begins_with("EditorInspectorSection"):
			var tip: String = node.tooltip_text.strip_edges()
			if tip == "":
				return {}
			if _has_letters(tip):
				return {"text": tip, "kind": "ui", "context": "inspector section", "where": "inspector"}
			if _has_cjk(tip):
				var en: String = _reverse(tip)
				if en != "":
					return {"text": en, "zh": tip, "kind": "ui", "context": "inspector section", "where": "inspector"}
				return {"text": tip, "zh": tip, "kind": "ui", "context": "inspector section", "where": "inspector"}
		node = node.get_parent()
	return {}

func _reverse(zh: String) -> String:
	if _translator and _translator.has_method("reverse_lookup"):
		return String(_translator.call("reverse_lookup", zh))
	return ""

func _property_display(prop: String) -> String:
	var parts := prop.replace("-", "_").split("_", false)
	var out: Array[String] = []
	for p in parts:
		var s := String(p)
		if s == "":
			continue
		out.append(s.substr(0, 1).to_upper() + s.substr(1))
	return " ".join(out)

func _has_cjk(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x4E00 and c <= 0x9FFF:
			return true
	return false

func _has_letters(s: String) -> bool:
	for i in s.length():
		var c := s[i]
		if (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			return true
	return false
