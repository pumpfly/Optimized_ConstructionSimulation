extends Node

## Structured simulation logger.
## Every line carries [sim=Xs wall=Yms] so you can correlate simulation-time
## with wall-clock time and find where the two diverge (= bottleneck).
##
## Usage:
##   DebugLog.log_printer("[TAG] message")
##   var t = DebugLog.start_perf()
##   ... do work ...
##   DebugLog.end_perf("label", t)
##
## Set DebugLog.sim_clock to the Stopwatch node at sim start so log lines
## include the current simulation time.  Clear it when the sim ends.

var sim_clock: Node = null  # Stopwatch node — set by simulation_main per run

var enabled: bool = true

var _log_file: FileAccess = null
var _log_path: String = ""
var _run_index: int = 0  # Incremented on each reset() so runs are distinguishable


func _ready() -> void:
	var pid := OS.get_process_id()
	var ts  := int(Time.get_unix_time_from_system())
	_log_path = "user://sim_log_pid%d_%d.txt" % [pid, ts]
	_log_file = FileAccess.open(_log_path, FileAccess.WRITE)
	if _log_file:
		_log_file.store_line("=== DebugLog opened | PID=%d | %s ===" % [pid, Time.get_datetime_string_from_system()])
		_log_file.flush()
	print("[DebugLog] Logging to: %s" % ProjectSettings.globalize_path(_log_path))


## Call at the start of each simulation run.
## Assigns the stopwatch so sim-time appears in every log line.
func begin_run(stopwatch: Node) -> void:
	_run_index += 1
	sim_clock = stopwatch
	#log_printer("=== RUN %d BEGIN ===" % _run_index)


## Call when the simulation run ends (finished or timed out).
func end_run(reason: String) -> void:
	var sim_t: float = sim_clock.get_time() if sim_clock else -1.0
	log_printer("=== RUN %d END | reason=%s | final_sim_time=%.2fs ===" % [_run_index, reason, sim_t])
	sim_clock = null

## Core log_printer call — every other helper routes through here.
func log_printer(msg: String) -> void:
	if not enabled:
		return
	var sim_t: float = sim_clock.get_time() if sim_clock else -1.0
	var wall: float = Time.get_ticks_msec()
	var line: String = "[sim=%.2f wall=%d] %s" % [sim_t, wall, msg]
	print(line)
	if _log_file:
		_log_file.store_line(line)
		_log_file.flush()


## Returns current wall-clock microseconds.  Pass the return value to end_perf().
func start_perf() -> int:
	return Time.get_ticks_usec()


## Logs how long a measured block took (in µs / ms).
func end_perf(label: String, start_us: int) -> void:
	var us := Time.get_ticks_usec() - start_us
	log_printer("[PERF] %s | %.1fµs (%.3fms)" % [label, float(us), us / 1000.0])


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _log_file:
		_log_file.store_line("=== DebugLog closed ===")
		_log_file.close()
		_log_file = null
