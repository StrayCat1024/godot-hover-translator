@tool
extends Node
## External Edge-TTS voice. It is used when the system voice is unavailable
## (for example when the editor runs at low integrity), or when the user wants
## the nicer online voice. A background process generates an MP3 on the first
## hover; later hovers use the cache.
##
## Windows calls `python -m edge_tts`. macOS / Linux prefer the `edge-tts`
## console script (pip / pipx / Homebrew) and fall back to `python3 -m edge_tts`.

const CACHE_DIR_NAME := "HoverTranslator"
const CACHE_SUBDIR := "tts_edge"
const MAX_TEXT := 500
const DEFAULT_VOICE := "en-US-GuyNeural"

var enabled := true
var voice_name := DEFAULT_VOICE
var timeout := 15.0
var volume_db := -3.0

var python_cmd := "python"
var python_args: PackedStringArray = []
var edge_cmd := ""
var python_found := false
var available := false
var checked := false
var probe_error := ""

var _player: AudioStreamPlayer
var _mem: Dictionary = {}
var _cache_dir := ""
var _busy := false
var _active_pid := -1
var _active_seq := 0
var _active_text := ""
var _active_path := ""
var _active_started_ms := 0
var _latest_seq := 0
var _latest_text := ""
var _last_error := ""
var _downloads := 0
var _hits := 0
var _prepare_pid := -1
var _prepare_path := ""
var _prepare_key := ""
var _prepare_started := 0
var _prepare_busy := false

func _ready() -> void:
	set_process(true)
	_ensure_cache()
	_player = AudioStreamPlayer.new()
	_player.name = "EdgeVoicePlayer"
	_player.bus = "Master"
	add_child(_player)

func _ensure_cache() -> void:
	if _cache_dir != "":
		return
	_cache_dir = _platform_cache_dir()
	DirAccess.make_dir_recursive_absolute(_cache_dir)

func _platform_cache_dir() -> String:
	var home := OS.get_environment("HOME")
	match OS.get_name():
		"Windows":
			var profile := OS.get_environment("USERPROFILE")
			if profile == "":
				profile = home
			return profile.path_join("AppData/LocalLow").path_join(CACHE_DIR_NAME).path_join(CACHE_SUBDIR)
		"macOS":
			if home != "":
				return home.path_join("Library/Caches").path_join(CACHE_DIR_NAME).path_join(CACHE_SUBDIR)
		"Linux":
			if home != "":
				var cache_home := OS.get_environment("XDG_CACHE_HOME")
				if cache_home == "":
					cache_home = home.path_join(".cache")
				return cache_home.path_join(CACHE_DIR_NAME).path_join(CACHE_SUBDIR)
	return OS.get_user_data_dir().path_join(CACHE_SUBDIR)

func detect_available() -> bool:
	_ensure_cache()
	checked = true
	available = false
	python_found = false
	probe_error = ""
	edge_cmd = ""
	if OS.get_name() == "Windows":
		for exe in ["py", "python", "python3"]:
			var prefix: PackedStringArray = PackedStringArray(["-3"]) if exe == "py" else PackedStringArray()
			if exe != "py" and not _python_is_real(exe):
				# Skip the Microsoft Store alias: running it opens the Store.
				continue
			if _probe_python(exe, prefix):
				return true
		# PATH may be stale right after the one-click installer; look in the
		# standard per-user / all-user locations too.
		for exe in _python_locations():
			if _probe_python(exe, PackedStringArray()):
				return true
	else:
		# macOS / Linux: the edge-tts console script is the most reliable
		# entry point (pip --user, pipx, Homebrew all install it on PATH).
		if _probe_edge_cli():
			return true
		for exe in ["python3", "python"]:
			if _probe_python(exe, PackedStringArray()):
				return true
	if python_found:
		_last_error = "未安装 edge-tts，请运行 %s" % _install_command()
	else:
		_last_error = "未检测到 Python，请先安装 Python 或改用系统语音"
	return false

func _install_command() -> String:
	if OS.get_name() == "Windows":
		return "“安装 Edge TTS”"
	return "python3 -m pip install --user edge-tts"

func _probe_edge_cli() -> bool:
	var found := ""
	var out: Array = []
	if OS.execute("which", ["edge-tts"], out, true) == 0:
		var path := String(out[0]).strip_edges() if out.size() > 0 else ""
		if path != "" and FileAccess.file_exists(path):
			found = path
	if found == "":
		for candidate in _edge_locations():
			if FileAccess.file_exists(candidate):
				found = candidate
				break
	if found == "":
		return false
	edge_cmd = found
	python_found = true
	available = true
	_last_error = ""
	return true

func _edge_locations() -> Array[String]:
	var list: Array[String] = []
	var home := OS.get_environment("HOME")
	if OS.get_name() == "macOS":
		list.append("/opt/homebrew/bin/edge-tts")
		list.append("/usr/local/bin/edge-tts")
		# `pip install --user` on macOS puts scripts here, not in ~/.local/bin.
		if home != "":
			var py_root := home.path_join("Library/Python")
			if DirAccess.dir_exists_absolute(py_root):
				for d in DirAccess.get_directories_at(py_root):
					list.append(py_root.path_join(d).path_join("bin/edge-tts"))
	else:
		list.append("/usr/bin/edge-tts")
		list.append("/usr/local/bin/edge-tts")
	if home != "":
		list.append(home.path_join(".local/bin/edge-tts"))
	return list

func _python_is_real(exe: String) -> bool:
	var locator := "where" if OS.get_name() == "Windows" else "which"
	var out: Array = []
	OS.execute(locator, [exe], out, true)
	var first := String(out[0]).strip_edges() if out.size() > 0 else ""
	if first == "":
		return false
	if OS.get_name() == "Windows":
		return not first.to_lower().contains("windowsapps")
	# macOS ships /usr/bin/python3 as a stub that prompts for Xcode Command
	# Line Tools. Do not trigger that dialog while just probing the voice.
	if first == "/usr/bin/python3":
		var probe: Array = []
		if OS.execute("/usr/bin/xcode-select", ["-p"], probe, true) != 0:
			return false
	return true

func _probe_python(exe: String, prefix: PackedStringArray) -> bool:
	var out: Array = []
	if OS.execute(exe, prefix + PackedStringArray(["-c", "print('ok')"]), out, true) != 0:
		return false
	python_found = true
	python_cmd = exe
	python_args = prefix
	out.clear()
	if OS.execute(exe, prefix + PackedStringArray(["-c", "import edge_tts"]), out, true) == 0:
		available = true
		_last_error = ""
		return true
	probe_error = String(out[0]).strip_edges() if out.size() > 0 else ""
	return false

func _python_locations() -> Array[String]:
	var found: Array[String] = []
	var bases: Array[String] = []
	var local := OS.get_environment("LOCALAPPDATA")
	if local != "":
		bases.append(local.path_join("Programs/Python"))
	bases.append("C:/Program Files")
	for base in bases:
		if not DirAccess.dir_exists_absolute(base):
			continue
		for d in DirAccess.get_directories_at(base):
			if base.ends_with("Program Files") and not String(d).begins_with("Python"):
				continue
			var exe := base.path_join(d).path_join("python.exe")
			if FileAccess.file_exists(exe):
				found.append(exe)
	return found

func speak(text: String) -> bool:
	if not enabled:
		return false
	if checked and not available:
		return false
	var clean := text.strip_edges()
	if clean == "":
		return false
	if clean.length() > MAX_TEXT:
		clean = clean.substr(0, MAX_TEXT)
	_latest_text = clean
	_latest_seq += 1
	var seq := _latest_seq
	var key := _key(clean)
	if _mem.has(key):
		_hits += 1
		_play(_mem[key])
		return true
	var path := _path_for(key)
	if FileAccess.file_exists(path):
		var stream := _load_mp3(path)
		if stream != null:
			_mem[key] = stream
			_hits += 1
			_play(stream)
			return true
	if _busy:
		# The current process will finish and cache its result, then the latest
		# text is started (or played from cache).
		return true
	return _start(clean, seq)

func is_busy() -> bool:
	return _busy

func status_text() -> String:
	if not enabled:
		return "在线语音：已关闭"
	if checked and not available:
		if python_found:
			return "在线语音：未安装 edge-tts（%s）" % _install_command()
		return "在线语音：未检测到 Python（%s）" % _install_command()
	if _busy:
		return "在线语音：正在生成（%s）…" % voice_name
	if _last_error != "":
		return "在线语音：" + _last_error
	return "在线语音：%s · 缓存 %d 条" % [voice_name, _mem.size()]

func stop() -> void:
	_latest_seq += 1
	if _active_pid > 0 and OS.is_process_running(_active_pid):
		OS.kill(_active_pid)
	_active_pid = -1
	_busy = false
	if _prepare_pid > 0 and OS.is_process_running(_prepare_pid):
		OS.kill(_prepare_pid)
	_prepare_pid = -1
	_prepare_busy = false
	if _player != null:
		_player.stop()

func has_cache(text: String) -> bool:
	var clean := text.strip_edges()
	if clean == "":
		return false
	var key := _key(clean)
	return _mem.has(key) or FileAccess.file_exists(_path_for(key))

func prepare(text: String) -> void:
	# Hybrid mode: generate and cache an Edge clip silently while the system
	# voice is speaking. The clip is used the next time the same word is hovered.
	if not enabled:
		return
	if checked and not available:
		return
	var clean := text.strip_edges()
	if clean == "":
		return
	if clean.length() > MAX_TEXT:
		clean = clean.substr(0, MAX_TEXT)
	if has_cache(clean):
		return
	if _prepare_busy or _busy:
		return
	var key := _key(clean)
	_prepare_key = key
	_prepare_path = _path_for(key)
	if FileAccess.file_exists(_prepare_path):
		DirAccess.remove_absolute(_prepare_path)
	var pid := _spawn(clean, _prepare_path)
	if pid <= 0:
		return
	_prepare_pid = pid
	_prepare_started = Time.get_ticks_msec()
	_prepare_busy = true

func _process(_delta: float) -> void:
	if _prepare_busy:
		var prepare_elapsed := Time.get_ticks_msec() - _prepare_started
		if _prepare_pid > 0 and OS.is_process_running(_prepare_pid) and prepare_elapsed < int(timeout * 1000.0):
			pass
		else:
			if _prepare_pid > 0 and OS.is_process_running(_prepare_pid):
				OS.kill(_prepare_pid)
			_prepare_pid = -1
			_prepare_busy = false
			var prepared := _load_mp3(_prepare_path)
			if prepared != null:
				_mem[_prepare_key] = prepared
				_downloads += 1
	if not _busy:
		return
	var elapsed := Time.get_ticks_msec() - _active_started_ms
	if _active_pid > 0 and OS.is_process_running(_active_pid) and elapsed < int(timeout * 1000.0):
		return
	if _active_pid > 0 and OS.is_process_running(_active_pid):
		OS.kill(_active_pid)
		_active_pid = -1
		_busy = false
		_finish_failure("语音生成超时")
		return
	_finish_process()

func _start(text: String, seq: int) -> bool:
	_active_text = text
	_active_seq = seq
	_active_started_ms = Time.get_ticks_msec()
	_last_error = ""
	var key := _key(text)
	_active_path = _path_for(key)
	if FileAccess.file_exists(_active_path):
		DirAccess.remove_absolute(_active_path)
	_active_pid = _spawn(text, _active_path)
	if _active_pid <= 0:
		_busy = false
		available = false
		checked = true
		_finish_failure("找不到 edge-tts，请先运行 %s" % _install_command())
		return false
	_busy = true
	return true

func _spawn(text: String, path: String) -> int:
	if edge_cmd != "":
		return OS.create_process(edge_cmd, PackedStringArray([
			"--voice", voice_name,
			"--text", text,
			"--write-media", path,
		]))
	var args := python_args.duplicate()
	args.append_array(PackedStringArray([
		"-m", "edge_tts",
		"--voice", voice_name,
		"--text", text,
		"--write-media", path,
	]))
	var pid := OS.create_process(python_cmd, args)
	if pid <= 0 and python_cmd == "python":
		pid = OS.create_process("pythonw", args)
	elif pid <= 0 and python_cmd == "py":
		pid = OS.create_process("pyw", args)
	return pid

func _finish_process() -> void:
	var seq := _active_seq
	var text := _active_text
	var path := _active_path
	_busy = false
	_active_pid = -1
	var stream := _load_mp3(path)
	if stream != null:
		var key := _key(text)
		_mem[key] = stream
		_downloads += 1
		if seq == _latest_seq:
			_play(stream)
	else:
		_last_error = "语音生成失败（edge-tts 未返回有效 MP3）"
		# Let the next hover fall back to the system voice instead of retrying a
		# backend that is evidently not working.
		available = false
		checked = true
	if available and seq != _latest_seq and _latest_text != "":
		var latest_key := _key(_latest_text)
		if _mem.has(latest_key):
			_play(_mem[latest_key])
		else:
			_start(_latest_text, _latest_seq)

func _finish_failure(message: String) -> void:
	_last_error = message
	if available and _latest_text != "" and _latest_seq != _active_seq:
		_start(_latest_text, _latest_seq)

func _play(stream: AudioStream) -> void:
	if _player == null or stream == null:
		return
	_player.stop()
	_player.stream = stream
	_player.volume_db = volume_db
	_player.play()

func _load_mp3(path: String) -> AudioStreamMP3:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 1000:
		return null
	var first := bytes[0]
	if first != 0x49 and first != 0xFF:
		return null
	var stream := AudioStreamMP3.new()
	stream.data = bytes
	if stream.get_length() <= 0.01:
		return null
	return stream

func _key(text: String) -> String:
	return (voice_name + "|" + text).sha256_text()

func _path_for(key: String) -> String:
	_ensure_cache()
	return _cache_dir.path_join(key + ".mp3")
