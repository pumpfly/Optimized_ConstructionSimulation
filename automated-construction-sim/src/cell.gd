class_name Cell
extends RefCounted

# Grid coordinates (matches heightmap pixel position)
var grid_x: int
var grid_y: int

# World position in 3D space
var world_pos: Vector3

# Terrain data
var current_height: int  # Equals to the color the pixel on the heightmap has

# Occupancy and state tracking
var is_occupied: bool = false
var assigned_agent: Node3D = null  # Reference to agent working here
var obstacle_node: Node3D = null # Refrence to node that holds NavigationObstacles

enum WorkState{EMPTY, ASSIGNED, RESERVED, UNDER_CONSTRUCTION, COMPLETED}
enum OccupyingAgentType{NONE, BAGGER, DIRT_TRUCK, MATERIAL_TRUCK, CRANE} # What kind of Agent is sitting on this cell right now
var current_state: WorkState = WorkState.EMPTY
var current_occupying_agent_type = OccupyingAgentType.NONE

var is_construction_zone_cell = false
var is_pipe_placement_cell = false
var is_pipe_placed = false

# Constructor - called when Cell.new() is used
func _init(x: int, y: int, world_position: Vector3, height: int = 0):
	grid_x = x
	grid_y = y
	world_pos = world_position
	current_height = height

# Assign an agent to this cell
func assign_agent(agent: Node3D) -> bool:
	if is_occupied:
		return false

	assigned_agent = agent
	is_occupied = true
	current_state = WorkState.ASSIGNED
	return true

# Release the agent from this cell
func release_agent() -> void:
	assigned_agent = null
	is_occupied = false

func is_available() -> bool:
	return not is_occupied
