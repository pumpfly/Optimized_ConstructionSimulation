class_name Bagger
extends BaseNavigation

var id: int
var timer_digging: Timer

var current_construction_cell: Cell = null  # Track which cell is currently being excavated

var dirt_truck: CharacterBody3D = null # The Truck which stands next to the bagger and can be loaded

var is_available = true
var work_target: Vector3  # The cell position the bagger is currently assigned to work at

var reserved_neighbor_cells: Array[Cell] = []

enum WorkState{WORKING, EXITING}
var current_state = WorkState.WORKING

# Called when the node enters the scene tree for the first time.
func _ready():
	# Call parent _ready() so base navigation setup runs (sets up main)
	super._ready()
	id = get_parent().get_child_count()
	# Resolve via main so the node name is explicit rather than a fragile child index

	# Get construction zone from the grid (available via main.grid from parent)

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
		for cell in simulation_main.grid.construction_zone:
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
	return Vector3.ZERO

# Override: Define what the bagger does when it reaches its destination
# This gets called when arriving at a neighbor cell of a chosen construction zone cell or a neighbor cell around a truck for loading
func perform_work():
	if current_state == WorkState.WORKING:
		if dirt_truck:
			#print("assigned truck %s" %dirt_truck.id)
			current_construction_cell.current_state = Cell.WorkState.UNDER_CONSTRUCTION
			# Adding an obstacle to a cell that is currently being worked on by a bagger unsures that other agents do not drive through those cells
			add_construction_obstacle([current_construction_cell])
			timer_digging.start()
	elif current_state == WorkState.EXITING:
		self.queue_free()


func _on_timer_timeout():
	if !simulation_main.grid.is_construction_zone_excavated:
		# Only release the pairing when the truck is now full and about to leave.
		# If the truck still has capacity it will follow the bagger to the next cell.
		if dirt_truck == null || dirt_truck.is_full:
			is_available = true
			dirt_truck = null
		elif dirt_truck:
			dirt_truck.load_truck()
			# Marking cell as completed and lowering height + updating terrain
			current_construction_cell.current_state = Cell.WorkState.COMPLETED
			simulation_main.grid.on_construction_cell_completed()
			# Give pixel a darker red, because the height has been lowerd
			var x: int = current_construction_cell.grid_x
			var y: int = current_construction_cell.grid_y
			simulation_main.set_heightmap_depth_by_pixel(1.0/255, x, y)
			if dirt_truck.is_full:
				is_available = true
			else:
				dirt_truck.set_movement_target(work_target)
	else:
		current_state = WorkState.EXITING
		if dirt_truck:
			dirt_truck.current_state = dirt_truck.WorkState.EXITING
			dirt_truck.set_movement_target(dirt_truck.get_target())
	# Removing obstacle
	remove_construction_obstacle([current_construction_cell])
	set_movement_target(get_target())
