class_name BaseNavigation
extends CharacterBody3D

var spawnpoint: Vector3

var movement_speed: float
var movement_target_position: Vector3 = Vector3.ZERO
var has_reached_goal: bool = false

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D
@onready var main: SimulationMain = $SimulationMain

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
	navigation_agent.path_desired_distance = 0.5
	navigation_agent.target_desired_distance = 1
	navigation_agent.avoidance_enabled = true

	# If is_navigation_finished() returns true at startup (which it does when there's no target set yet), 
	# then actor_setup() never gets called, which means set_movement_target() never gets called
	# which is why we need this:
	actor_setup.call_deferred()
	
	spawnpoint = main.grid.get_spawn_cell().world_pos


func actor_setup():
	# Wait for the first physics frame so the NavigationServer can sync.
	await get_tree().physics_frame

	# Get the initial target from the agent's override
	movement_target_position = get_target()

	# Now that the navigation map is no longer empty, set the movement target.
	set_movement_target(movement_target_position)

func set_movement_target(movement_target: Vector3):
	navigation_agent.set_target_position(movement_target)
	
func _physics_process(_delta):
	if navigation_agent.is_navigation_finished():
		if !has_reached_goal:
			has_reached_goal = true
			on_destination_reached()
		return

	var current_agent_position: Vector3 = global_position
	var next_path_position: Vector3 = navigation_agent.get_next_path_position()

	velocity = current_agent_position.direction_to(next_path_position) * movement_speed
	if position != next_path_position:
		look_at(next_path_position)
	move_and_slide()
