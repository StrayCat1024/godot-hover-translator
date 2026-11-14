@tool
extends Node
## Cross-platform system speech helper.
##
## Windows keeps a persistent PowerShell/SAPI process: running speech in a
## separate process avoids the WinRT TTS crash some Godot 4.7 builds hit, and
## keeps the editor responsive while a word is being spoken.
##
## macOS uses the built-in `say` command. Linux uses speech-dispatcher
## (`spd-say`) or espeak-ng / espeak. Those are one-shot processes, so no
## helper script is needed and no audio file is written.

var pid: int = -1
var stdio: FileAccess
var stderr: FileAccess
var last_error: String = ""
var started := false

var _platform := ""
var _backend := ""          # sapi / say / spd-say / espeak-ng / espeak
var _system_voice := ""
var _speak_pid := -1

var _status_path := ""
var _log_path := ""
var _ready_flag := false
var _voice := ""
var _permanent := false
var _poll := 0.0
var _last_spoken := ""
var _last_spoken_ms := 0

func _ready() -> void:
	_platform = OS.get_name()
	set_process(true)

func start() -> void:
	stop()
	_permanent = false
	_ready_flag = false
	_voice = ""
	last_error = ""
	started = false
	if _platform == "":
		_platform = OS.get_name()
	if _platform == "Windows":
		_start_windows()
	else:
		_start_unix()

# --- Windows: persistent SAPI helper ---------------------------------------

func _start_windows() -> void:
	_backend = "sapi"
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

# --- macOS / Linux: one-shot system commands -------------------------------

func _start_unix() -> void:
	_system_voice = String(ProjectSettings.get_setting("hover_translator/voice", ""))
	if _platform == "macOS":
		_start_macos()
	elif _platform == "Linux":
		_start_linux()
	else:
		last_error = "当前平台不支持系统语音（%s）" % _platform
		_permanent = true

func _start_macos() -> void:
	var out: Array = []
	if OS.execute("say", ["-v", "?"], out, true) != 0:
		last_error = "找不到 macOS 的 say 命令"
		_permanent = true
		return
	_backend = "say"
	var voices := String(out[0]) if out.size() > 0 else ""
	var chosen := _pick_macos_voice(voices)
	_system_voice = chosen
	_voice = chosen if chosen != "" else "系统默认"
	_ready_flag = true
	started = true
	print("[HoverTranslator] TTS ready (macOS say): ", _voice)

func _pick_macos_voice(voices: String) -> String:
	if _system_voice != "" and voices.contains(_system_voice):
		return _system_voice
	var preferred := [
		"Samantha", "Alex", "Ava", "Allison", "Susan", "Daniel", "Karen",
		"Moira", "Tessa", "Fiona", "Veena", "Rishi",
		"Eddy (English (US))", "Reed (English (US))", "Rocko (English (US))",
		"Shelley (English (US))", "Grandma (English (US))",
		"Grandpa (English (US))",
	]
	for name in preferred:
		if voices.contains(String(name)):
			return String(name)
	for line in voices.split("\n", false):
		if line.contains("en_") or line.contains("en-"):
			var parts := line.strip_edges().split(" ", false)
			if parts.size() > 0:
				return String(parts[0]).strip_edges()
	return ""

func _start_linux() -> void:
	for exe in ["spd-say", "espeak-ng", "espeak"]:
		if not _command_exists(exe):
			continue
		_backend = exe
		_system_voice = "en"
		_voice = "speech-dispatcher" if exe == "spd-say" else exe
		_ready_flag = true
		started = true
		print("[HoverTranslator] TTS ready (Linux ", exe, ")")
		return
	last_error = "未找到系统语音（可安装 speech-dispatcher 或 espeak-ng）"
	_permanent = true

func _command_exists(exe: String) -> bool:
	var out: Array = []
	if OS.execute("which", [exe], out, true) == 0:
		var path := String(out[0]).strip_edges() if out.size() > 0 else ""
		if path != "":
			return true
	# Minimal distros may not ship `which`; ask the command for its help text.
	out.clear()
	OS.execute(exe, ["-h"], out, true)
	return out.size() > 0 and String(out[0]).strip_edges() != ""

# --- Public API ------------------------------------------------------------

func speak(text: String) -> bool:
	var t := text.strip_edges()
	if t == "":
		return false
	if _permanent:
		return false
	if _platform == "Windows":
		return _speak_windows(t)
	return _speak_unix(t)

func _speak_windows(t: String) -> bool:
	if stdio == null or pid <= 0 or not OS.is_process_running(pid):
		start()
	if stdio == null:
		return false
	stdio.store_line(t)
	stdio.flush()
	_last_spoken = t
	_last_spoken_ms = Time.get_ticks_msec()
	return true

func _speak_unix(t: String) -> bool:
	if not is_ready():
		start()
	if not is_ready():
		return false
	if _speak_pid > 0 and OS.is_process_running(_speak_pid):
		OS.kill(_speak_pid)
	_speak_pid = -1
	var args := PackedStringArray()
	match _backend:
		"say":
			if _system_voice != "":
				args.append_array(PackedStringArray(["-v", _system_voice]))
			args.append_array(PackedStringArray(["-r", str(_wpm_value())]))
			args.append(t)
		"spd-say":
			args.append_array(PackedStringArray(["-l", "en", "-r", str(_spd_rate()), "-w"]))
			args.append(t)
		"espeak-ng", "espeak":
			args.append_array(PackedStringArray(["-v", "en", "-s", str(_espeak_speed())]))
			args.append(t)
		_:
			return false
	var child := OS.create_process(_backend, args)
	if child <= 0:
		last_error = "无法启动系统语音：" + _backend
		return false
	_speak_pid = child
	_last_spoken = t
	_last_spoken_ms = Time.get_ticks_msec()
	return true

func _rate() -> int:
	return clampi(int(ProjectSettings.get_setting("hover_translator/rate", 0)), -10, 10)

func _wpm_value() -> int:
	return clampi(175 + _rate() * 12, 90, 400)

func _spd_rate() -> int:
	return clampi(_rate() * 8, -100, 100)

func _espeak_speed() -> int:
	return clampi(175 + _rate() * 12, 80, 450)

func stop() -> void:
	if _platform == "Windows":
		if stdio != null:
			stdio.store_line("__QUIT__")
			stdio.flush()
		stdio = null
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
		pid = -1
		if _status_path != "":
			_remove_file(_status_path)
	else:
		if _speak_pid > 0 and OS.is_process_running(_speak_pid):
			OS.kill(_speak_pid)
		_speak_pid = -1
	started = false
	_ready_flag = false

func restart() -> void:
	start()

func is_ready() -> bool:
	if _platform == "Windows":
		return _ready_flag and pid > 0 and OS.is_process_running(pid)
	return _ready_flag and started

func current_voice() -> String:
	return _voice

func status() -> String:
	if _permanent:
		return "语音不可用：" + _friendly_error(last_error)
	if _platform == "Windows":
		if pid > 0 and OS.is_process_running(pid):
			if _ready_flag:
				return "语音就绪：" + _voice
			return "语音启动中…"
		if last_error != "":
			return "语音不可用：" + _friendly_error(last_error)
		return "语音未启动"
	if is_ready():
		return "语音就绪：" + _voice
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
	if _platform != "Windows":
		if _speak_pid > 0 and not OS.is_process_running(_speak_pid):
			_speak_pid = -1
		return
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
	if _platform != "Windows":
		return m
	if m.contains("安全设置") or m.contains("未安装语音") or m.contains("拒绝访问") or m.contains("权限") or m.contains("沙箱"):
		return "Windows 权限/沙箱阻止了语音。请关闭编辑器，从桌面图标正常启动 Godot。"
	if m.contains("denied") or m.contains("restricted") or m.contains("sandbox") or m.contains("No usable voice") or m.contains("Access is denied"):
		return "Windows 权限/沙箱阻止了语音。请关闭编辑器，从桌面图标正常启动 Godot。"
	return m

func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
