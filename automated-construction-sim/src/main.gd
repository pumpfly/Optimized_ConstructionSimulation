extends Node

@onready var simulation_scene: PackedScene = preload("res://Constructionsim.tscn")
var simulation_instance: Node = null  # Store the instantiated scene
var timer: Timer
var stop_watch: Node = null
var current_task_id: int = -1
var _run_wall_start_ms: int = 0

# Checks if the simulation scene is currently running
func is_simulation_running() -> bool:
	return simulation_instance != null and is_instance_valid(simulation_instance) and simulation_instance.is_inside_tree()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	timer = Timer.new()
	timer.wait_time = 1
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)
	timer.start()

func _on_timer_timeout():
	# Creates an HTTP request node and connects its completion signal.
	var http_request: HTTPRequest = HTTPRequest.new()
	add_child(http_request)

	var error = http_request.request("http://127.0.0.1:7999/input")
	print("asking for work")
	if error != OK:
		push_error("An error occurred in the HTTP request.")

	# The function _http_request_completed gets called
	http_request.request_completed.connect(self._http_request_completed)
	# Cleanup
	http_request.request_completed.connect(http_request.queue_free.unbind(4))

# Called when the HTTP request is completed.
func _http_request_completed(result, _response_code, _headers, body):
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("something went wrong")
		return

	# If all tasks are done: terminate
	if body.size() > 0 and body[0] == 102:
		print("finished")
		return

	timer.stop()

	# Parse the JSON response from the orchestrator
	var response_text = body.get_string_from_utf8()
	var parsed = JSON.parse_string(response_text)
	if parsed == null:
		push_error("Failed to parse JSON from orchestrator: " + response_text)
		timer.start()
		return

	current_task_id = int(parsed["id"])
	print("Task ID: " + str(current_task_id))

	# Convert string keys to int keys (JSON requires string keys)
	var int_schedule: Dictionary = {}
	for key in parsed["schedule"].keys():
		int_schedule[int(key)] = parsed["schedule"][key]

	# Initialize Constructionsim Scene
	print("Creating simulation instance...")
	simulation_instance = simulation_scene.instantiate()
	# Pass schedule before adding to tree so _ready() sees it
	simulation_instance.agent_schedule = int_schedule
	add_child(simulation_instance)
	print("Simulation added to tree")
	stop_watch = simulation_instance.get_node("StopWatch")

	# Connect DebugLog to the new stopwatch so all log lines carry sim-time
	_run_wall_start_ms = Time.get_ticks_msec()
	DebugLog.begin_run(stop_watch)
	DebugLog.log_printer("[MAIN] Task id=%d | schedule=%s" % [current_task_id, str(int_schedule)])

	# Connect finish/timeout signals — handover is sent from those callbacks
	simulation_instance.construction_finished.connect(_construction_finished)
	simulation_instance.stop_watch.timeout.connect(_construction_timout)


func _send_handover():
	# TODO: replace randi answer with real simulation metric
	var answer = randi_range(0, 1000)
	var url_string = "http://127.0.0.1:7999/handover?answer=%s&id=%s"
	var actual_url = url_string % [answer, current_task_id]

	var http_request = HTTPRequest.new()
	http_request.request_completed.connect(http_request.queue_free.unbind(4))
	add_child(http_request)

	var error = http_request.request(actual_url)
	if error != OK:
		push_error("An error occurred in the handover HTTP request.")


func _construction_timout():
	var wall_elapsed = Time.get_ticks_msec() - _run_wall_start_ms
	DebugLog.log_printer("[MAIN] TIMEOUT | sim_time=%.2fs | wall_elapsed=%dms" % [stop_watch.get_time(), wall_elapsed])
	DebugLog.end_run("timeout")
	print("!!construction took too long!! - Freeing simulation")
	_send_handover()
	simulation_instance.queue_free()
	timer.start()

func _construction_finished():
	var wall_elapsed = Time.get_ticks_msec() - _run_wall_start_ms
	DebugLog.log_printer("[MAIN] FINISHED | sim_time=%.2fs | wall_elapsed=%dms | speedup=%.1fx" % [
		stop_watch.get_time(), wall_elapsed,
		stop_watch.get_time() / (wall_elapsed / 1000.0) if wall_elapsed > 0 else 0.0])
	DebugLog.end_run("finished")
	print("construction finished - Freeing simulation")
	_send_handover()
	simulation_instance.queue_free()
	timer.start()
