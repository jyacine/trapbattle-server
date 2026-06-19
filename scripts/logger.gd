extends Node
class_name GameLogger

# One log file per calendar day.  Files older than MAX_LOG_FILES days are
# deleted automatically when the new file is opened (day rollover or startup).
# Location: user://logs/server_YYYY-MM-DD.log
# On Linux that resolves to ~/.local/share/godot/app_userdata/<project>/logs/
const LOG_DIR       := "user://logs/"
const MAX_LOG_FILES := 7

static var instance: GameLogger = null

var _file:         FileAccess = null
var _current_date: String     = ""

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	instance = self
	# Ensure the logs directory exists (user:// is guaranteed to be writable)
	if not DirAccess.dir_exists_absolute(OS.get_user_data_dir().path_join("logs")):
		DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir().path_join("logs"))
	_open_log_file()
	_cleanup_old_logs()
	_write_line("INFO", "=== TrapBattle Server started — log dir: %s ===" %
		OS.get_user_data_dir().path_join("logs"))

func _open_log_file() -> void:
	_current_date = Time.get_date_string_from_system()
	var path := LOG_DIR + "server_%s.log" % _current_date
	if FileAccess.file_exists(path):
		_file = FileAccess.open(path, FileAccess.READ_WRITE)
		if _file:
			_file.seek_end()   # append to today's existing file
	else:
		_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("[Logger] Cannot open log file %s (err %d)" % [path, FileAccess.get_open_error()])

func _cleanup_old_logs() -> void:
	var dir := DirAccess.open(LOG_DIR)
	if dir == null:
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.begins_with("server_") and fname.ends_with(".log"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	files.sort()   # YYYY-MM-DD sorts chronologically
	while files.size() > MAX_LOG_FILES:
		var old := files.pop_front()
		dir.remove(old)
		_write_line("INFO", "Log rotation: deleted %s (keeping last %d days)" % [old, MAX_LOG_FILES])

# ────────────────────────────────────────────────────────────────────────────
func _ts() -> String:
	return Time.get_datetime_string_from_system().replace("T", " ")

func _maybe_rotate() -> void:
	var today := Time.get_date_string_from_system()
	if today == _current_date:
		return
	_write_line("INFO", "=== Day rolled over to %s — rotating log ===" % today)
	if _file:
		_file.close()
		_file = null
	_open_log_file()
	_cleanup_old_logs()

# Low-level writer — does NOT check rotation (safe to call from within rotation).
func _write_line(level: String, msg: String) -> void:
	var line := "[%s] [%s] %s" % [_ts(), level, msg]
	print(line)   # also goes to stdout / journald
	if _file:
		_file.store_line(line)
		_file.flush()  # flush immediately so crashes don't lose the last lines

func _write(level: String, msg: String) -> void:
	_maybe_rotate()
	_write_line(level, msg)

# ── Static public API — call as Logger.info("…") from anywhere ───────────────
static func info(msg: String) -> void:
	if instance: instance._write("INFO", msg)
	else: print("[INFO] " + msg)

static func warn(msg: String) -> void:
	if instance: instance._write("WARN", msg)
	else: push_warning(msg)

static func error(msg: String) -> void:
	if instance: instance._write("ERROR", msg)
	else: push_error(msg)
