class_name Bagger
extends BaseNavigation

var timer_digging: Timer

var grid: Grid
var construction_zone: Array[Cell]
var current_construction_cell: Cell = null  # Track which cell is currently being excavated

var dirt_truck: CharacterBody3D = null # The Truck which stands next to the bagger and can be loaded

var is_available = true

@onready var obstacle_container: Node3D = %ObstacleContainer

enum WorkPhase{WORKING, EXITING}
var current_phase = WorkPhase.WORKING

# Called when the node enters the scene tree for the first time.
func _ready():
	# Call parent _ready() so base navigation setup runs
	super._ready()

	# Get construction zone from the grid (available via main.grid from parent)
	construction_zone = main.grid.get_construction_zone()
	
	# Set agent-specific properties
	movement_speed = 5.0
	
	timer_digging = Timer.new()
	timer_digging.wait_time = 120 # That is how long it takes for a midsized excavator to finish one cubic meter (on average)
	timer_digging.timeout.connect(_on_timer_timeout)
	add_child(timer_digging)
	

# Override: Define where the bagger should go
func get_target() -> Vector3:
	if current_phase == WorkPhase.WORKING:
		var cell_index_x: int = 0
		var cell_index_y: int = 0
		
		if current_construction_cell != null: # So that the bagger does not search from the first cell everytime it finished another
			cell_index_x = current_construction_cell.grid_x
			cell_index_y = current_construction_cell.grid_y
		# Start searching
		for x in range(cell_index_x, grid.grid_width):
			for y in range(cell_index_y, grid.grid_height):
				var cell: Cell = grid.grid[x][y]
				if cell.current_state != Cell.WorkState.EMPTY:
					continue
				else:
					current_construction_cell = cell
					current_construction_cell.current_state = Cell.WorkState.ASSIGNED
					
					return current_construction_cell.world_pos
	elif current_phase == WorkPhase.EXITING:
		return spawnpoint
	return Vector3.ZERO 

# Override: Define what the bagger does when it reaches its destination
# This gets called when arriving at a neighbor cell of a chosen construction zone cell or a neighbor cell around a truck for loading
func perform_work():
	if dirt_truck:
		current_construction_cell.current_state = Cell.WorkState.UNDER_CONSTRUCTION
		add_construction_obstacle(current_construction_cell)
		timer_digging.start()


func _on_timer_timeout():
	# loading truck
	dirt_truck.get_script().load_truck()
	
	# Marking cell as completed and lowering height + updating terrain
	current_construction_cell.current_state = Cell.WorkState.COMPLETED
	var x: int = current_construction_cell.grid_x
	var y: int = current_construction_cell.grid_y
	main.set_heightmap_depth_by_pixel(-1, x, y)
	
	# Setting new goal
	set_movement_target(get_target())
	has_reached_goal = false
	

# Adding an obstacle to a cell that is currently being worked on by a bagger unsures that other agents do not drive through those cells
func add_construction_obstacle(cell: Cell) -> void:
	var obstacle = NavigationObstacle3D.new()
	obstacle.avoidance_enabled = true
	obstacle.radius = 1 # Cell width
	obstacle.position = cell.world_pos

	obstacle_container.add_child(obstacle)

func remove_construction_obstacle(cell: Cell) -> void:
	if cell.obstacle_node:
		cell.obstacle_node.queue_free()
		cell.obstacle_node = null
