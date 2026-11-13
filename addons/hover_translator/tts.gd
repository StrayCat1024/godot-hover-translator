@tool
extends Node
## Persistent Windows SAPI helper. Running speech in a separate process avoids
## the WinRT TTS crash some Godot 4.7 builds hit on Windows, and keeps the editor
## responsive while a word is being spoken.

var pid: int = -1
var stdio: FileAccess
var stderr: FileAccess
var last_error: String = ""
var started := false

var _status_path := ""
var _log_path := ""
var _ready_flag := false
var _voice := ""
var _permanent := false
var _poll := 0.0
var _last_spoken := ""
var _last_spoken_ms := 0

func _ready() -> void:
	set_process(true)

func start() -> void:
	stop()
	_permanent = false
	_ready_flag = false
	_voice = ""
	last_error = ""
	var script_path := ProjectSettings.globalize_path("res://addons/hover_translator/tts_helper.ps1")
	if not FileAccess.file_exists(script_path):
		last_error = "找不到 tts_helper.ps1"
		_permanent = true
		return
	_log_path = ProjectSettings.globalize_path("user://hover_translator_tts.log")
	_status_path = ProjectSettings.globalize_path("user://hover_translator_tts.status")
	_remove_file(_status_path)
	var voice := String(ProjectSettings.get_setting("hover_translator/voice", "Microsoft Zira Desktop"))
	var rate := int(ProjectSettings.get_setting("hover_translator/rate", 0))
	var volume := int(ProjectSettings.get_setting("hover_translator/volume", 100))
	var args := [
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-WindowStyle", "Hidden",
		"-File", script_path,
		"-Voice", voice,
		"-Rate", str(rate),
		"-Volume", str(volume),
		"-LogPath", _log_path,
		"-StatusPath", _status_path,
	]
	var info := OS.execute_with_pipe("powershell.exe", args, false)
	pid = int(info.get("pid", -1))
	stdio = info.get("stdio")
	stderr = info.get("stderr")
	started = true
	_poll = 0.0
	print("[HoverTranslator] TTS start pid=", pid, " log=", _log_path, " status=", _status_path)
	if pid <= 0 or stdio == null:
		last_error = "无法启动 PowerShell 语音进程"
		started = false
		print("[HoverTranslator] TTS spawn failed: ", info)
	else:
		last_error = ""

func speak(text: String) -> bool:
	var t := text.strip_edges()
	if t == "":
		return false
	if _permanent:
		return false
	if stdio == null or pid <= 0 or not OS.is_process_running(pid):
		start()
	if stdio == null:
		return false
	stdio.store_line(t)
	stdio.flush()
	_last_spoken = t
	_last_spoken_ms = Time.get_ticks_msec()
	return true

func stop() -> void:
	if stdio != null:
		stdio.store_line("__QUIT__")
		stdio.flush()
	stdio = null
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
	pid = -1
	started = false
	_ready_flag = false
	if _status_path != "":
		_remove_file(_status_path)

func restart() -> void:
	start()

func is_ready() -> bool:
	return _ready_flag and pid > 0 and OS.is_process_running(pid)

func status() -> String:
	if _permanent:
		return "语音不可用：" + _friendly_error(last_error)
	if pid > 0 and OS.is_process_running(pid):
		if _ready_flag:
			return "语音就绪：" + _voice
		return "语音启动中…"
	if last_error != "":
		return "语音不可用：" + _friendly_error(last_error)
	return "语音未启动"

func detail() -> String:
	var parts: Array[String] = []
	if _voice != "":
		parts.append("语音：" + _voice)
	if _log_path != "":
		parts.append("日志：" + _log_path)
	if last_error != "":
		parts.append("错误：" + last_error)
	return "  ".join(parts)

func _process(delta: float) -> void:
	if not started:
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = 0.4
	_poll_status()

func _poll_status() -> void:
	if _status_path != "" and FileAccess.file_exists(_status_path):
		var text := FileAccess.get_file_as_string(_status_path).strip_edges()
		var line: String = text.split("\n", false)[0] if text != "" else ""
		if line.begins_with("READY|"):
			_ready_flag = true
			_voice = line.substr(6).strip_edges()
			last_error = ""
		elif line.begins_with("ERROR|"):
			_ready_flag = false
			last_error = line.substr(6).strip_edges()
			_permanent = true
			started = false
			print("[HoverTranslator] TTS error: ", last_error)
			if pid > 0 and OS.is_process_running(pid):
				OS.kill(pid)
			pid = -1
			return
		elif line == "STOPPED":
			_ready_flag = false
	if pid > 0 and not OS.is_process_running(pid):
		_ready_flag = false
		started = false
		if stderr != null:
			var err_text := stderr.get_as_text().strip_edges()
			if err_text != "":
				print("[HoverTranslator] TTS stderr:\n", err_text)
		if not _permanent and last_error == "":
			last_error = "语音进程已退出（可能是 Windows 权限/沙箱限制）"
			print("[HoverTranslator] TTS process exited; ", last_error)

func _friendly_error(message: String) -> String:
	var m := message
	if m == "":
		m = "未知错误"
	if m.contains("安全设置") or m.contains("未安装语音") or m.contains("拒绝访问") or m.contains("权限") or m.contains("沙箱"):
		return "Windows 权限/沙箱阻止了语音。请关闭编辑器，从桌面图标正常启动 Godot。"
	if m.contains("denied") or m.contains("restricted") or m.contains("sandbox") or m.contains("No usable voice") or m.contains("Access is denied"):
		return "Windows 权限/沙箱阻止了语音。请关闭编辑器，从桌面图标正常启动 Godot。"
	return m

func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
