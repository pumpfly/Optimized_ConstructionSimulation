extends Node

const LOG_PATH := "user://sim_debug.log"

func _ready() -> void:
	# Truncate/create the log file fresh each run
	var f := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f:
		f.store_line("=== Simulation started: %s ===" % Time.get_datetime_string_from_system())
	print("[DebugLog] Logging to: ", ProjectSettings.globalize_path(LOG_PATH))

func log(msg: String) -> void:
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(msg)
	else:
		# File didn't exist yet — create it
		f = FileAccess.open(LOG_PATH, FileAccess.WRITE)
		if f:
			f.store_line(msg)
