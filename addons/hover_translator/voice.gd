@tool
extends Node
## External Edge-TTS voice. It is used when Windows SAPI is unavailable
## (for example when the editor runs at low integrity). A background Python
## process generates an MP3 on the first hover; later hovers use the cache.

const CACHE_DIR_NAME := "HoverTranslator"
const CACHE_SUBDIR := "tts_edge"
const MAX_TEXT := 500
const DEFAULT_VOICE := "en-US-GuyNeural"

var enabled := true
var voice_name := DEFAULT_VOICE
var timeout := 15.0
var volume_db := -3.0

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

func _ready() -> void:
	set_process(true)
	_cache_dir = OS.get_environment("USERPROFILE").path_join("AppData/LocalLow").path_join(CACHE_DIR_NAME).path_join(CACHE_SUBDIR)
	DirAccess.make_dir_recursive_absolute(_cache_dir)
	_player = AudioStreamPlayer.new()
	_player.name = "EdgeVoicePlayer"
	_player.bus = "Master"
	add_child(_player)

func speak(text: String) -> bool:
	if not enabled:
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
	_start(clean, seq)
	return true

func is_busy() -> bool:
	return _busy

func status_text() -> String:
	if not enabled:
		return "在线语音：已关闭"
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
	if _player != null:
		_player.stop()

func _process(_delta: float) -> void:
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

func _start(text: String, seq: int) -> void:
	_active_text = text
	_active_seq = seq
	_active_started_ms = Time.get_ticks_msec()
	_last_error = ""
	var key := _key(text)
	_active_path = _path_for(key)
	if FileAccess.file_exists(_active_path):
		DirAccess.remove_absolute(_active_path)
	var args := [
		"-m", "edge_tts",
		"--voice", voice_name,
		"--text", text,
		"--write-media", _active_path,
	]
	_active_pid = OS.create_process("python", args)
	if _active_pid <= 0:
		_active_pid = OS.create_process("pythonw", args)
	if _active_pid <= 0:
		_busy = false
		_finish_failure("找不到 Python / edge-tts，请先安装 edge-tts")
		return
	_busy = true

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
	if seq != _latest_seq and _latest_text != "":
		var latest_key := _key(_latest_text)
		if _mem.has(latest_key):
			_play(_mem[latest_key])
		else:
			_start(_latest_text, _latest_seq)

func _finish_failure(message: String) -> void:
	_last_error = message
	if _latest_text != "" and _latest_seq != _active_seq:
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
	return _cache_dir.path_join(key + ".mp3")
