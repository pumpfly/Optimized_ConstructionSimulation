extends CharacterBody3D

var movement_speed: float = 2.0
var movement_target_position: Vector3 = Vector3(0.0,0.0,0.0)
var has_reached_goal: bool = false

signal goal_reached 

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

func _ready():
	# These values need to be adjusted for the actor's speed
	# and the navigation layout.
	navigation_agent.path_desired_distance = 0.5
	navigation_agent.target_desired_distance = 0.5

	# Make sure to not await during _ready.
	# If is_navigation_finished() returns true at startup (which it does when there's no target set yet), 
	# then actor_setup() never gets called, which means set_movement_target() never gets called
	# which is why we need this:
	actor_setup.call_deferred()

func actor_setup():
	# Wait for the first physics frame so the NavigationServer can sync.
	await get_tree().physics_frame

	# Now that the navigation map is no longer empty, set the movement target.
	set_movement_target(movement_target_position)

func set_movement_target(movement_target: Vector3):
	navigation_agent.set_target_position(movement_target)
	
func _physics_process(_delta):
	if navigation_agent.is_navigation_finished():
		if !has_reached_goal:  # Only emit the FIRST time we detect it's finished
			has_reached_goal = true
			goal_reached.emit() 
		return

	var current_agent_position: Vector3 = global_position
	var next_path_position: Vector3 = navigation_agent.get_next_path_position()

	velocity = current_agent_position.direction_to(next_path_position) * movement_speed
	if !navigation_agent.is_navigation_finished() && position != next_path_position:
		look_at(next_path_position)
	move_and_slide()
