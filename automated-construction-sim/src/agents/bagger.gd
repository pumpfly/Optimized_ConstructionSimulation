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

# Timing
var _cell_assign_sim_t: float = 0.0   # sim time when bagger was assigned this cell
var _dig_start_sim_t:   float = 0.0   # sim time when digging timer started
var _cells_completed:   int   = 0
var _no_cell_poll_counter: int = 0

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
	DebugLog.log_printer("[BAGGER] id=%d spawned | dig_timer=%.1fs | speed=%.1f" % [id, timer_digging.wait_time, movement_speed])


func _process(_delta: float) -> void:
	# If excavation finished while we were idle, release any paired truck then self-exit
	if simulation_main.grid.is_construction_zone_excavated and current_state == WorkState.WORKING:
		DebugLog.log_printer("[BAGGER] id=%d detected excavation_done while idle → EXITING" % id)
		if dirt_truck:
			dirt_truck.current_state = dirt_truck.WorkState.EXITING
			dirt_truck.set_movement_target(dirt_truck.get_target())
		current_state = WorkState.EXITING
		set_movement_target(get_target())
		return
	# Poll for an empty cell if we're stuck with none assigned
	if has_reached_goal and current_construction_cell == null and current_state == WorkState.WORKING:
		_no_cell_poll_counter += 1
		if _no_cell_poll_counter >= 120:
			_no_cell_poll_counter = 0
			var next := get_target()
			if next != Vector3.ZERO:
				set_movement_target(next)


# Override
func get_target() -> Vector3:
	#print("[Bagger] %s" %id)
	if current_state == WorkState.WORKING:
		for cell in simulation_main.grid.construction_zone:
			if cell.current_state == Cell.WorkState.EMPTY:
				current_construction_cell = cell
				current_construction_cell.current_state = Cell.WorkState.ASSIGNED
				current_construction_cell.assigned_agent = self
				work_target = current_construction_cell.world_pos
				_cell_assign_sim_t = simulation_main.stop_watch.get_time()
				DebugLog.log_printer("[BAGGER] id=%d assigned cell=(%d,%d) world_pos=%s" % [
					id, cell.grid_x, cell.grid_y, work_target])
				return work_target
		DebugLog.log_printer("[BAGGER] id=%d get_target returned ZERO — no empty cells found" % id)
	elif current_state == WorkState.EXITING:
		return spawnpoint
	return Vector3.ZERO

# Override: Define what the bagger does when it reaches its destination
# This gets called when arriving at a neighbor cell of a chosen construction zone cell or a neighbor cell around a truck for loading
func perform_work():
	if current_state == WorkState.WORKING:
		if current_construction_cell == null:
			# Truck arrived but bagger has no cell yet — release truck so it can retry pairing
			if dirt_truck:
				dirt_truck.is_being_loaded = false
				dirt_truck.current_bagger = null
				dirt_truck = null
			is_available = true
			return
		var travel_to_cell: float = simulation_main.stop_watch.get_time() - _cell_assign_sim_t
		if dirt_truck:
			DebugLog.log_printer("[BAGGER] id=%d START_DIG | cell=(%d,%d) | travel_to_cell=%.2fs | truck=%s" % [
				id, current_construction_cell.grid_x, current_construction_cell.grid_y,
				travel_to_cell, dirt_truck.name])
			current_construction_cell.current_state = Cell.WorkState.UNDER_CONSTRUCTION
			# Adding an obstacle to a cell that is currently being worked on by a bagger unsures that other agents do not drive through those cells
			add_construction_obstacle([current_construction_cell])
			_dig_start_sim_t = simulation_main.stop_watch.get_time()
			timer_digging.start()
		else:
			DebugLog.log_printer("[BAGGER] id=%d ARRIVED_NO_TRUCK | cell=(%d,%d) | travel=%.2fs — waiting for truck" % [
				id, current_construction_cell.grid_x, current_construction_cell.grid_y, travel_to_cell])
	elif current_state == WorkState.EXITING:
		DebugLog.log_printer("[BAGGER] id=%d EXITING — queue_free | total_cells_completed=%d" % [id, _cells_completed])
		self.queue_free()


func _on_timer_timeout():
	if current_construction_cell == null:
		return
	var dig_duration: float = simulation_main.stop_watch.get_time() - _dig_start_sim_t
	if !simulation_main.grid.is_construction_zone_excavated:
		# Only release the pairing when the truck is now full and about to leave.
		# If the truck still has capacity it will follow the bagger to the next cell.
		if dirt_truck == null || dirt_truck.is_full:
			DebugLog.log_printer("[BAGGER] id=%d CELL_DONE (no truck) | cell=(%d,%d) | dig_duration=%.2fs — resetting to EMPTY" % [
				id, current_construction_cell.grid_x, current_construction_cell.grid_y, dig_duration])
			is_available = true
			dirt_truck = null
		elif dirt_truck:
			dirt_truck.load_truck()
			# Marking cell as completed and lowering height + updating terrain
			current_construction_cell.current_state = Cell.WorkState.COMPLETED
			simulation_main.grid.on_construction_cell_completed()
			_cells_completed += 1
			DebugLog.log_printer("[BAGGER] id=%d CELL_COMPLETED | cell=(%d,%d) | dig_duration=%.2fs | cells_done=%d/%d" % [
				id, current_construction_cell.grid_x, current_construction_cell.grid_y,
				dig_duration, simulation_main.grid.completed_cc_zone,
				simulation_main.grid.construction_zone.size()])
			# Give pixel a darker red, because the height has been lowerd
			var x: int = current_construction_cell.grid_x
			var y: int = current_construction_cell.grid_y
			simulation_main.set_heightmap_depth_by_pixel(1.0/255, x, y)
			if dirt_truck.is_full:
				is_available = true
			else:
				dirt_truck.set_movement_target(work_target)
	else:
		DebugLog.log_printer("[BAGGER] id=%d all cells excavated → EXITING | total_completed=%d" % [id, _cells_completed])
		current_state = WorkState.EXITING
		if dirt_truck:
			dirt_truck.current_state = dirt_truck.WorkState.EXITING
			dirt_truck.set_movement_target(dirt_truck.get_target())
	# Removing obstacle
	remove_construction_obstacle([current_construction_cell])
	current_construction_cell = null
	set_movement_target(get_target())
