class_name MaterialTruck
extends BaseNavigation

var park_rng = RandomNumberGenerator.new() # For deciding what point should be chosen to park during idle
var is_empty: bool = false
var load_count: int = 2

var crane_parent: Node = null   # Set by agent_spawner; used to find an available crane
var target_crane: Crane = null  # Cached once a WORKING crane is found
var _log_throttle: float = 0.0

# Timing
var _spawn_sim_t: float = 0.0
var _crane_wait_start_sim_t: float = 0.0  # how long truck waited for crane to park
var _trips_completed: float = 0.0

@onready var pipe_1: MeshInstance3D = $Pivot/LKW_with_pipes/pipe_1
@onready var pipe_2: MeshInstance3D = $Pivot/LKW_with_pipes/pipe_2

enum WorkState {IDLE, WORKING, EXITING}
var current_state = WorkState.IDLE


func _ready():
	super._ready()
	navigation_agent.radius = 2.0
	navigation_agent.target_desired_distance = 10
	_spawn_sim_t = simulation_main.stop_watch.get_time()
	DebugLog.log_printer("[MAT_TRUCK] %s spawned | load=%d | speed=%.1f | spawn_sim_t=%.2f" % [
		name, load_count, movement_speed, _spawn_sim_t])

func _process(delta: float) -> void:
	super._process(delta)
	# Poll until a crane in WORKING state is available, then start driving towards it
	if target_crane == null:
		target_crane = _find_working_crane()
		if target_crane:
			_crane_wait_start_sim_t = simulation_main.stop_watch.get_time()
			DebugLog.log_printer("[MAT_TRUCK] %s CRANE_FOUND | crane=%s | crane_state=%s" % [
				name, target_crane.name, Crane.WorkState.keys()[target_crane.curr_work_state]])

	_log_throttle += delta
	if _log_throttle >= 1.0:
		_log_throttle = 0
		var crane_state_str := "null"
		var has_parked_str := "null"
		if target_crane:
			crane_state_str = Crane.WorkState.keys()[target_crane.curr_work_state]
			has_parked_str = str(target_crane.has_parked)
		DebugLog.log_printer("[MAT_TRUCK _process] %s | truck_state=%s | target_crane=%s | crane_state=%s | has_parked=%s | pos=%s | reached_goal=%s" % [
			name, WorkState.keys()[current_state],
			"found" if target_crane else "null",
			crane_state_str, has_parked_str,
			global_position, has_reached_goal])

	if target_crane && current_state == WorkState.IDLE && target_crane.has_parked:
		var wait_time: float = simulation_main.stop_watch.get_time() - _crane_wait_start_sim_t
		DebugLog.log_printer("[MAT_TRUCK→WORKING] %s | pos=%s | crane_pos=%s | waited_for_park=%.2fs" % [
			name, global_position, target_crane.global_position, wait_time])
		current_state = WorkState.WORKING
		set_movement_target(get_target())

func _find_working_crane() -> Crane:
	for child in crane_parent.get_children():
		if child is Crane && child.curr_work_state == Crane.WorkState.WORKING:
			return child
	return null

func get_target() -> Vector3:
	if current_state == WorkState.WORKING && target_crane:
		return target_crane.global_position
	elif current_state == WorkState.EXITING:
		return spawnpoint
	var x_random = park_rng.randi_range(10, 20)
	var z_random = park_rng.randi_range(10, 20)
	return Vector3(spawnpoint.x + x_random, 0, spawnpoint.z - z_random)

func perform_work():
	DebugLog.log_printer("[MAT_TRUCK perform_work] %s | state=%s | pos=%s | crane=%s | dist_to_crane=%.2f | load=%d" % [
		name, WorkState.keys()[current_state], global_position,
		"found" if target_crane else "null",
		global_position.distance_to(target_crane.global_position) if target_crane else -1.0,
		load_count])
	if current_state == WorkState.WORKING && target_crane:
		target_crane.request_pipe_pickup(self)
	elif current_state == WorkState.EXITING:
		_trips_completed += 1
		DebugLog.log_printer("[MAT_TRUCK] %s EXITING — queue_free | trips_completed=%d" % [name, _trips_completed])
		queue_free()

# Called by the crane once all pipes have been unloaded from this truck
func on_unloaded() -> void:
	var sim_t: float = simulation_main.stop_watch.get_time()
	DebugLog.log_printer("[MAT_TRUCK] %s ON_UNLOADED | sim_t=%.2fs | load_count_was=%d → 0" % [name, sim_t, load_count])
	is_empty = true
	current_state = WorkState.EXITING
	navigation_agent.target_desired_distance = 3.0
	set_movement_target(get_target())
