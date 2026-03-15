class_name Crane
extends BaseNavigation

var pipe_placement_cells: Array[Cell] = []

enum WorkState{IDLE, WORKING, EXITING}
var curr_work_state: WorkState = WorkState.IDLE

var truck_queue: Array[MaterialTruck] = []
var is_placing: bool = false
var has_parked: bool = false  # True once crane has physically arrived at construction zone
var current_pipe_cell_index: int = 0
var timer_placement: Timer
var pipe: PackedScene

# Timing
var _spawn_sim_t: float = 0.0
var _park_start_sim_t: float = 0.0       # when crane started moving to construction zone
var _placement_start_sim_t: float = 0.0  # when current pipe placement started
var _pipes_placed: int = 0


func _ready():
	super._ready()
	pipe_placement_cells = simulation_main.grid.get_pipe_placements()
	navigation_agent.radius = 5
	# The target is the furthest pipe cell, which is inside the construction zone.
	# Avoidance obstacles on the zone keep the crane ~7.5 units from the zone boundary,
	# and the target may be 15-20 units deeper inside. target_desired_distance must
	# cover that full depth so is_navigation_finished() can fire at the zone edge.
	navigation_agent.target_desired_distance = 25.0

	timer_placement = Timer.new()
	timer_placement.wait_time = 300 #  5 minutes
	timer_placement.one_shot = true
	timer_placement.timeout.connect(_on_placement_timer_timeout)
	add_child(timer_placement)

	_spawn_sim_t = simulation_main.stop_watch.get_time()
	DebugLog.log_printer("[CRANE] spawned | pipe_cells=%d | placement_timer=%.1fs | speed=%.1f | spawn_sim_t=%.2f" % [
		pipe_placement_cells.size(), timer_placement.wait_time, movement_speed, _spawn_sim_t])

func get_target() -> Vector3:
	if curr_work_state == WorkState.IDLE:
		return spawnpoint/1.25
	elif curr_work_state == WorkState.WORKING:
		return furthest_pipe_placement_cell().world_pos
	elif curr_work_state == WorkState.EXITING:
		return spawnpoint
	return Vector3.ZERO

func actor_setup():
	await super.actor_setup()
	DebugLog.log_printer("[CRANE _post_start] pos=%s | excavated=%s | state=%s" % [
		global_position, simulation_main.grid.is_construction_zone_excavated, WorkState.keys()[curr_work_state]])
	# If this crane was spawned after excavation already completed, the signal
	# fired once and won't fire again — activate directly here instead.
	# The IDLE guard prevents double-activation if the signal also connected normally.
	if simulation_main.grid.is_construction_zone_excavated && curr_work_state == WorkState.IDLE:
		DebugLog.log_printer("[CRANE _post_start] excavation already done — calling on_excavation_complete directly")
		on_excavation_complete()

func on_excavation_complete():
	var wait_since_spawn: float = simulation_main.stop_watch.get_time() - _spawn_sim_t
	curr_work_state = WorkState.WORKING
	add_construction_obstacle(simulation_main.grid.construction_zone) # The crane should not drive directly on the construction zone, just closer to it
	DebugLog.log_printer("[CRANE on_excavation_complete] pos=%s | pipe_cells=%d | wait_since_spawn=%.2fs" % [
		global_position, pipe_placement_cells.size(), wait_since_spawn])
	_park_start_sim_t = simulation_main.stop_watch.get_time()
	set_movement_target(get_target())

func perform_work():
	DebugLog.log_printer("[CRANE perform_work] state=%s | pos=%s | has_parked=%s | truck_queue=%d" % [
		WorkState.keys()[curr_work_state], global_position, has_parked, truck_queue.size()])
	if curr_work_state == WorkState.IDLE:
		return
	elif curr_work_state == WorkState.EXITING:
		for truck in truck_queue:
			truck.on_unloaded()
		DebugLog.log_printer("[CRANE] CONSTRUCTION_FINISHED | pipes_placed=%d | pipes_total=%d" % [
			_pipes_placed, pipe_placement_cells.size()])
		simulation_main.construction_finished.emit()
		self.queue_free()
		return
	# Crane has arrived at the construction zone.
	var drive_time: float = simulation_main.stop_watch.get_time() - _park_start_sim_t
	has_parked = true
	DebugLog.log_printer("[CRANE parked] pos=%s | drive_time=%.2fs | truck_queue=%d" % [
		global_position, drive_time, truck_queue.size()])
	# Drain any trucks that already queued up while the crane was driving.
	if !truck_queue.is_empty() && !is_placing:
		start_next_pipe_placement()

# Called by MaterialTruck when it arrives near the crane
func request_pipe_pickup(truck: MaterialTruck):
	truck_queue.append(truck)
	DebugLog.log_printer("[CRANE request_pipe_pickup] truck=%s | queue_size=%d | is_placing=%s" % [
		truck.name, truck_queue.size(), is_placing])
	if !is_placing:
		start_next_pipe_placement()

func start_next_pipe_placement():
	if current_pipe_cell_index >= pipe_placement_cells.size():
		# All pipe cells have been filled — crane is done regardless of truck queue state
		DebugLog.log_printer("[CRANE] all %d pipe cells placed → EXITING" % pipe_placement_cells.size())
		curr_work_state = WorkState.EXITING
		set_movement_target(get_target())
		return
	if truck_queue.is_empty():
		DebugLog.log_printer("[CRANE] start_next_pipe_placement: truck_queue empty — waiting")
		is_placing = false
		return
	is_placing = true
	_placement_start_sim_t = simulation_main.stop_watch.get_time()
	DebugLog.log_printer("[CRANE] PLACEMENT_START | pipe_index=%d/%d | truck=%s | timer=%.1fs" % [
		current_pipe_cell_index, pipe_placement_cells.size(), truck_queue.front().name, timer_placement.wait_time])
	timer_placement.start()

func _on_placement_timer_timeout():
	var placement_duration: float = simulation_main.stop_watch.get_time() - _placement_start_sim_t
	var truck = truck_queue.front()
	# Remove the next pipe mesh from the truck visually
	if truck.load_count == 2:
		truck.pipe_1.queue_free()
	elif truck.load_count == 1:
		truck.pipe_2.queue_free()
	# Place pipe on construction zone
	var pipe_instance = pipe.instantiate()
	var pipe_placement: Vector3 = pipe_placement_cells[current_pipe_cell_index].world_pos
	pipe_instance.position = Vector3(pipe_placement.x + 0.5, 0, pipe_placement.z + 0.5)
	simulation_main.add_child(pipe_instance)
	truck.load_count -= 1
	current_pipe_cell_index += 1
	_pipes_placed += 1
	DebugLog.log_printer("[CRANE] PLACEMENT_DONE | pipe#%d | cell=(%d,%d) | duration=%.2fs | truck_load_remaining=%d" % [
		_pipes_placed,
		pipe_placement_cells[current_pipe_cell_index - 1].grid_x,
		pipe_placement_cells[current_pipe_cell_index - 1].grid_y,
		placement_duration, truck.load_count])
	# Dismiss truck immediately once empty — don't wait for another 300s timer cycle
	if truck.load_count == 0:
		truck.on_unloaded()
		truck_queue.pop_front()
	start_next_pipe_placement()
	

# If the cell, that is furtherst away, is inside the reach of crane, every other placement cell will be as well
func furthest_pipe_placement_cell() -> Cell:
	var curr_max_distance: float = 0
	var furthest_cell: Cell
	for p in pipe_placement_cells:
		var distance_vector: Vector3 = self.position - p.world_pos
		var distance_length: float = vector_length_formular(distance_vector)
		if distance_length >= curr_max_distance:
			curr_max_distance = distance_length
			furthest_cell = p
	return furthest_cell


func vector_length_formular(vec: Vector3) -> float:
	return sqrt(pow(vec.x, 2) + pow(vec.y, 2) + pow(vec.z, 2))
