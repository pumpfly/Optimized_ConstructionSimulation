class_name BaseNavigation
extends CharacterBody3D

var spawnpoint: Vector3

var movement_speed: float = 5.0
var movement_target_position: Vector3 = Vector3.ZERO
var has_reached_goal: bool = false

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var main: SimulationMain = self.get_parent().get_parent().get_parent()

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

	# If is_navigation_finished() returns true at startup (which it does when there's no target set yet),
	# then actor_setup() never gets called, which means set_movement_target() never gets called
	# which is why we need this:
	actor_setup.call_deferred()

	# so that return trips target the correct height instead of the grid cell's Y=0.
	var spawn_xz = main.grid.get_spawn_cell().world_pos
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
	movement_target.y = position.y
	navigation_agent.set_target_position(movement_target)
	#var nav_map = navigation_agent.get_navigation_map()
	# NOTE: do NOT call is_navigation_finished() here — it calls _update_navigation() which has
	# side effects (can set target_position_submitted=false, navigation_finished=true immediately).
	#print("[NAV] set_movement_target → target=%s | map_iteration_id=%s" % [
		#movement_target,
		#NavigationServer3D.map_get_iteration_id(nav_map),
	#])

	has_reached_goal = false

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity = safe_velocity
	move_and_slide()

func _physics_process(_delta):
	if navigation_agent.is_navigation_finished():
		if !has_reached_goal:
			has_reached_goal = true
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
