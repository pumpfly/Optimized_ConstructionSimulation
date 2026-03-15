class_name BaseNavigation
extends CharacterBody3D

var spawnpoint: Vector3

var movement_speed: float = 5.0
var movement_target_position: Vector3 = Vector3.ZERO
var has_reached_goal: bool = false
# Guards against is_navigation_finished() returning a stale true immediately after
# set_movement_target() is called, before the NavigationServer has computed the new path.
var _path_cooldown: int = 0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var simulation_main: SimulationMain = self.get_parent().get_parent().get_parent()
var obstacle_container: Node3D

# --- Travel timing ---
var _travel_start_sim_t:  float = 0.0
var _travel_start_wall_us: int  = 0
var _travel_start_pos:    Vector3 = Vector3.ZERO
var _travel_trip_index:   int    = 0  # counts how many trips this agent has made

# --- Idle timing (time between arriving and starting next movement) ---
var _idle_start_wall_us: int = 0

var _ptick_count: int = 0
var _ptick_window_us: int = 0

## "Virtual" methods - agents should override them
func get_target() -> Vector3:
	# Default implementation
	return Vector3.ZERO

# agents define their work behavior
func perform_work():
	pass

func on_destination_reached():
	perform_work()


func _ready():
	navigation_agent.path_desired_distance =  0.5
	navigation_agent.target_desired_distance = 3
	navigation_agent.avoidance_enabled = true
	navigation_agent.debug_enabled = true
	# Avoidance in Godot 4 requires feeding desired velocity into the agent so the
	# NavigationServer can negotiate between all agents and return a safe velocity.
	navigation_agent.velocity_computed.connect(_on_velocity_computed)
	
	obstacle_container = simulation_main.get_node("ObstacleContainer")

	# If is_navigation_finished() returns true at startup (which it does when there's no target set yet),
	# then actor_setup() never gets called, which means set_movement_target() never gets called
	# which is why we need this:
	actor_setup.call_deferred()

	# so that return trips target the correct height instead of the grid cell's Y=0.
	var spawn_xz = simulation_main.grid.get_spawn_cell().world_pos
	spawnpoint = Vector3(spawn_xz.x, 0, spawn_xz.z)


func actor_setup():
	# Wait until the NavigationServer has completed at least one map sync.
	# physics_frame fires BEFORE NavigationServer.physics_process() (which does the sync),
	# so on the very first frame query_path() silently returns [] (iteration_id == 0).
	# map_changed is emitted AFTER sync completes, guaranteeing a valid map.
	var nav_map = navigation_agent.get_navigation_map()
	while NavigationServer3D.map_get_iteration_id(nav_map) == 0:
		await NavigationServer3D.map_changed

	# Get the initial target from the agent's override
	movement_target_position = get_target()

	# Now that the navigation map is no longer empty, set the movement target.
	set_movement_target(movement_target_position)
	# _physics_process may have set has_reached_goal = true during the await
	# (is_navigation_finished() returns true before any path is set). Reset it
	# so on_destination_reached() fires correctly when the real target is reached.
	has_reached_goal = false

func set_movement_target(movement_target: Vector3):
	# Log idle time (gap between arriving and starting next movement)
	if _idle_start_wall_us > 0:
		var idle_ms := (Time.get_ticks_usec() - _idle_start_wall_us) / 1000.0
		DebugLog.log_printer("[IDLE] %s | waited %.2fms wall before next move" % [name, idle_ms])
		_idle_start_wall_us = 0

	# Start travel timer
	_travel_start_sim_t   = simulation_main.stop_watch.get_time()
	_travel_start_wall_us = Time.get_ticks_usec()
	_travel_start_pos     = global_position
	_travel_trip_index   += 1
	var dist := global_position.distance_to(movement_target)
	DebugLog.log_printer("[TRAVEL_START] %s trip#%d | from=%s to=%s | straight_dist=%.1f | speed=%.1f" % [
		name, _travel_trip_index, global_position, movement_target, dist, movement_speed])

	movement_target.y = position.y
	navigation_agent.set_target_position(movement_target)
	movement_target_position = movement_target
	# NOTE: do NOT call is_navigation_finished() here — it calls _update_navigation() which has
	# side effects (can set target_position_submitted=false, navigation_finished=true immediately).
	has_reached_goal = false
	_path_cooldown = 2

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity = safe_velocity
	move_and_slide()

func _physics_process(_delta):
	# Tick sampler
	_ptick_count += 1
	if _ptick_count == 1:
		_ptick_window_us = Time.get_ticks_usec()
	elif _ptick_count > 300:
		var avg := float(Time.get_ticks_usec() - _ptick_window_us) / 300.0
		DebugLog.log_printer("[PERF_PTICK] %s | avg=%.1fµs/tick over 300 ticks" % [name, avg])
		_ptick_count = 1
		_ptick_window_us = Time.get_ticks_usec()

	if _path_cooldown > 0:
		_path_cooldown -= 1
		return
	if navigation_agent.is_navigation_finished():
		if !has_reached_goal:
			has_reached_goal = true

			# Log travel completion
			var elapsed_sim: float  = simulation_main.stop_watch.get_time() - _travel_start_sim_t
			var elapsed_wall_ms := (Time.get_ticks_usec() - _travel_start_wall_us) / 1000.0
			var dist_actual  := _travel_start_pos.distance_to(global_position)
			DebugLog.log_printer("[TRAVEL_END] %s trip#%d | pos=%s | dist_actual=%.1f | sim_elapsed=%.2fs | wall=%.2fms" % [
				name, _travel_trip_index, global_position, dist_actual, elapsed_sim, elapsed_wall_ms])

			# Start idle timer — measures how long until next set_movement_target()
			_idle_start_wall_us = Time.get_ticks_usec()

			on_destination_reached()
		return
	var current_agent_position: Vector3 = global_position
	var next_path_position: Vector3 = navigation_agent.get_next_path_position()

	# DIAGNOSTIC: print when path is empty (agent would stand still)
	#if navigation_agent.get_current_navigation_path().is_empty():
		#var nav_map = navigation_agent.get_navigation_map()
		#print("[NAV] path empty in _physics_process | map_iteration_id=%s | target=%s | agent_pos=%s" % [
			#NavigationServer3D.map_get_iteration_id(nav_map),
			#navigation_agent.get_target_position(),
			#global_position
		#])

	# Push desired velocity into the agent; velocity_computed fires with the avoidance-adjusted result
	var desired_velocity = current_agent_position.direction_to(next_path_position) * movement_speed
	navigation_agent.velocity = desired_velocity

	var look_target = Vector3(next_path_position.x, current_agent_position.y, next_path_position.z)
	if current_agent_position.distance_to(look_target) > 0.01:
		look_at(look_target)

func add_construction_obstacle(cells: Array[Cell]) -> void:
	for c in cells:
		if c.obstacle_node:
			return  # already exists — perform_work() was called twice
		var obstacle = NavigationObstacle3D.new()
		#var obstacle_mesh:MeshInstance3D = MeshInstance3D.new() #DEBUG
		obstacle.avoidance_enabled = true
		obstacle.radius = 0.5 # Cell width
		obstacle.position = c.world_pos
		#obstacle_mesh.mesh = BoxMesh.new() #DEBUG
		obstacle_container.add_child(obstacle) #DEBUG
		#obstacle.add_child(obstacle_mesh)
		c.obstacle_node = obstacle
	

func remove_construction_obstacle(cells: Array[Cell]) -> void:
	for c in cells:
		if c.obstacle_node:
			obstacle_container.remove_child(c.obstacle_node)
			c.obstacle_node.queue_free()
			c.obstacle_node = null
