class_name MaterialTruck
extends BaseNavigation

var is_empty: bool = false
var load_count: int = 2

var crane_parent: Node = null   # Set by agent_spawner; used to find an available crane
var target_crane: Crane = null  # Cached once a WORKING crane is found
var _log_throttle: int = 0

@onready var pipe_1: MeshInstance3D = $Pivot/LKW_with_pipes/pipe_1
@onready var pipe_2: MeshInstance3D = $Pivot/LKW_with_pipes/pipe_2

enum WorkState {IDLE, WORKING, EXITING}
var current_state = WorkState.IDLE

const CRANE_APPROACH_DISTANCE: float = 9.0  # Crane disables avoidance when parked, so trucks can approach to just outside the body (crane radius ~7)

func _ready():
	navigation_agent.radius = 2.0
	super._ready()

func _process(_delta: float) -> void:
	# Poll until a crane in WORKING state is available, then start driving toward it
	if target_crane == null:
		target_crane = _find_working_crane()

	_log_throttle += 1
	if _log_throttle >= 60:
		_log_throttle = 0
		var crane_state_str := "null"
		var has_parked_str := "null"
		if target_crane:
			crane_state_str = Crane.WorkState.keys()[target_crane.curr_work_state]
			has_parked_str = str(target_crane.has_parked)
		DebugLog.log("[TRUCK _process] %s | truck_state=%s | target_crane=%s | crane_state=%s | has_parked=%s | truck_pos=%s | cooldown=%d | has_reached_goal=%s" % [
			name, WorkState.keys()[current_state],
			"found" if target_crane else "null",
			crane_state_str, has_parked_str,
			global_position, _path_cooldown, has_reached_goal])

	if target_crane && current_state == WorkState.IDLE && target_crane.has_parked:
		DebugLog.log("[TRUCK→WORKING] %s | truck_pos=%s | crane_pos=%s | crane_has_parked=%s" % [
			name, global_position, target_crane.global_position, target_crane.has_parked])
		current_state = WorkState.WORKING
		navigation_agent.target_desired_distance = CRANE_APPROACH_DISTANCE
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
	# Pick a random navmesh point near spawn so multiple trucks don't stack on each other
	var base := Vector3(spawnpoint.x - 5, 0, spawnpoint.z - 5)
	var random_offset := Vector3(randf_range(-6.0, 6.0), 0.0, randf_range(-6.0, 6.0))
	var nav_map := navigation_agent.get_navigation_map()
	return NavigationServer3D.map_get_closest_point(nav_map, base + random_offset)

func perform_work():
	DebugLog.log("[TRUCK perform_work] %s | state=%s | pos=%s | target_crane=%s | dist_to_crane=%.2f" % [
		name, WorkState.keys()[current_state], global_position,
		"found" if target_crane else "null",
		global_position.distance_to(target_crane.global_position) if target_crane else -1.0])
	if current_state == WorkState.WORKING && target_crane:
		target_crane.request_pipe_pickup(self)
	elif current_state == WorkState.EXITING:
		queue_free()

# Called by the crane once all pipes have been unloaded from this truck
func on_unloaded() -> void:
	is_empty = true
	current_state = WorkState.EXITING
	navigation_agent.target_desired_distance = 3.0
	set_movement_target(get_target())
