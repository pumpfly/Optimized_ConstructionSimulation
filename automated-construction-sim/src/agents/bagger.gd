class_name Bagger
extends BaseNavigation

var id: int

var timer_digging: Timer

var grid: Grid
var construction_zone: Array[Cell]
var current_construction_cell: Cell = null  # Track which cell is currently being excavated

var dirt_truck: CharacterBody3D = null # The Truck which stands next to the bagger and can be loaded

var is_available = true
var work_target: Vector3  # The cell position the bagger is currently assigned to work at

var obstacle_container: Node3D
var reserved_neighbor_cells: Array[Cell] = []

enum WorkState{WORKING, EXITING}
var current_state = WorkState.WORKING

# Called when the node enters the scene tree for the first time.
func _ready():
	# Call parent _ready() so base navigation setup runs (sets up main)
	super._ready()
	id = get_parent().get_child_count()
	# Resolve via main so the node name is explicit rather than a fragile child index
	obstacle_container = main.get_node("ObstacleContainer")

	# Get construction zone from the grid (available via main.grid from parent)
	construction_zone = main.grid.get_construction_zone()

	# Set agent-specific properties
	movement_speed = 5.0
	navigation_agent.target_desired_distance = 0.5
	
	navigation_agent.radius = 0.6

	timer_digging = Timer.new()
	timer_digging.wait_time = 120 # That is how long it takes for a midsized excavator to finish one cubic meter (on average)
	timer_digging.timeout.connect(_on_timer_timeout)
	add_child(timer_digging)
	

# Override
func get_target() -> Vector3:
	#print("[Bagger] %s" %id)
	if current_state == WorkState.WORKING:
		for cell in construction_zone:
			#print("Cell current state: %s Cell index: %s Cell pos: %s" %[cell.current_state, Vector2(cell.grid_x, cell.grid_y), cell.world_pos])
			if cell.current_state == Cell.WorkState.EMPTY:
				current_construction_cell = cell
				#print("Chosen cell state: %s" %cell.current_state)
				current_construction_cell.current_state = Cell.WorkState.ASSIGNED
				current_construction_cell.assigned_agent = self
				work_target = current_construction_cell.world_pos
				#print ("Target : %s" %current_construction_cell.world_pos)
				return work_target
		#return spawnpoint # No available cells
	elif current_state == WorkState.EXITING:
		return spawnpoint
	return spawnpoint

# Override: Define what the bagger does when it reaches its destination
# This gets called when arriving at a neighbor cell of a chosen construction zone cell or a neighbor cell around a truck for loading
func perform_work():
	if current_state == WorkState.WORKING:
		if dirt_truck:
			#print("assigned truck %s" %dirt_truck.id)
			current_construction_cell.current_state = Cell.WorkState.UNDER_CONSTRUCTION
			add_construction_obstacle(current_construction_cell)
			timer_digging.start()
	else:
		self.queue_free()


func _on_timer_timeout():
	if !grid.is_construction_zone_excavated:
		# Only release the pairing when the truck is now full and about to leave.
		# If the truck still has capacity it will follow the bagger to the next cell.
		if dirt_truck == null || dirt_truck.is_full:
			is_available = true
			dirt_truck = null
		elif dirt_truck:
			dirt_truck.load_truck()
			# Marking cell as completed and lowering height + updating terrain
			current_construction_cell.current_state = Cell.WorkState.COMPLETED
			main.grid.on_construction_cell_completed()
			# Removing obstacle
			remove_construction_obstacle(current_construction_cell)
			# Give pixel a darker red, because the height has been lowerd
			var x: int = current_construction_cell.grid_x
			var y: int = current_construction_cell.grid_y
			main.set_heightmap_depth_by_pixel(1.0/255, x, y)
			if dirt_truck.is_full:
				is_available = true
			else:
				set_movement_target(get_target())
				dirt_truck.set_movement_target(work_target)
	else:
		print("construction zone is excavated")
		current_state = WorkState.EXITING
		dirt_truck.current_state = dirt_truck.WorkState.EXITING


# Adding an obstacle to a cell that is currently being worked on by a bagger unsures that other agents do not drive through those cells
func add_construction_obstacle(cell: Cell) -> void:
	if cell.obstacle_node:
		return  # already exists — perform_work() was called twice (once by bagger, once via truck)
	var obstacle = NavigationObstacle3D.new()
	obstacle.avoidance_enabled = true
	obstacle.radius = 0.5 # Cell width
	obstacle.position = cell.world_pos

	obstacle_container.add_child(obstacle)
	cell.obstacle_node = obstacle

func remove_construction_obstacle(cell: Cell) -> void:
	if cell.obstacle_node:
		obstacle_container.remove_child(cell.obstacle_node)
		cell.obstacle_node.queue_free()
		cell.obstacle_node = null
