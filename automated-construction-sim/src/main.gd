extends Node

@onready var simulation_scene: PackedScene = preload("res://Constructionsim.tscn")
@onready var stop_watch: Node = %StopWatch
var simulation_instance: Node = null  # Store the instantiated scene
var timer: Timer

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

	# Initialize Constructionsim Scene
	# Create instance of a scene.
	print("Creating simulation instance...")
	simulation_instance = simulation_scene.instantiate()
	add_child(simulation_instance)
	print("Simulation added to tree")

	# If the construction process has not finished in 2 hours, than stop simulation
	stop_watch.timeout.connect(_construction_timout)
	
	# Get Task ID
	var response_text = body.get_string_from_utf8()
	var id = response_text.to_int()
	print("Task ID: " + str(id))

	var answer = randi_range(0, 1000)
	
	# Handover
	## The URL
	var url_string = "http://127.0.0.1:7999/handover?answer=%s&id=%s"
	var actualUrl_string = url_string % [answer, id]
	
	## New HTTPRequest for Handover
	var http_request_2 = HTTPRequest.new()
	http_request_2.request_completed.connect(http_request_2.queue_free.unbind(4))
	add_child(http_request_2)
	
	var error = http_request_2.request(actualUrl_string)
	if error != OK:
		push_error("An error occurred in the HTTP request.")

func _construction_timout():
	print("!!construction took too long!! - Freeing simulation")
	timer.start()
	simulation_instance.queue_free()

func _construction_finished():
	print("construction finished - Freeing simulation")
	timer.start()
	simulation_instance.queue_free() 
