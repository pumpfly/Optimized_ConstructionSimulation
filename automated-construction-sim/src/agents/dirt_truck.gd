class_name DirtTruck
extends BaseNavigation


var is_being_loaded = false

var is_full = false
var capacity: int = 20 # cells or cubic meters
var current_load_level: int = 0
var current_bagger: Node3D = null

enum WorkState{WORKING, EXITING}
var current_state = WorkState.WORKING

@onready var baggers = self.get_parent().get_parent().get_node("BaggerParent")
@onready var id = self.get_parent().get_child_count()

# Timing
var _round_trip_start_sim_t: float = 0.0  # sim time at start of each round trip
var _round_trips_completed: float = 0.0
var _bagger_seek_start_sim_t: float = 0.0  # how long we spent looking for a bagger
var _no_bagger_log_throttle: float = 0.0
var _no_bagger_poll_counter: float = 0.0

func _ready():
	super._ready()
	navigation_agent.radius = 1
	navigation_agent.target_desired_distance = 2
	_round_trip_start_sim_t = simulation_main.stop_watch.get_time()
	DebugLog.log_printer("[DIRT_TRUCK] id=%d spawned | capacity=%d | speed=%.1f" % [id, capacity, movement_speed])

func _process(delta: float) -> void:
	super._process(delta)
	# Self-exit if excavation finished while we were still in WORKING state
	if current_state == WorkState.WORKING and simulation_main.grid.is_construction_zone_excavated:
		DebugLog.log_printer("[DIRT_TRUCK] id=%d detected excavation_done → EXITING" % id)
		current_state = WorkState.EXITING
		set_movement_target(get_target())
		return
	# If we reached our destination but still have no bagger, poll every 60 frames
	if has_reached_goal and current_bagger == null and current_state == WorkState.WORKING:
		_no_bagger_poll_counter += delta
		if _no_bagger_poll_counter >= 0.0033:
			_no_bagger_poll_counter = 0
			var next := get_target()
			if next != Vector3.ZERO:
				set_movement_target(next)


func get_target() -> Vector3:
	if current_state == WorkState.WORKING:
		if current_bagger:
			return current_bagger.work_target
		# Seeking a bagger
		if _bagger_seek_start_sim_t == 0.0:
			_bagger_seek_start_sim_t = simulation_main.stop_watch.get_time()
		for b: Node3D in baggers.get_children():
			if b.is_available:
				var seek_time: float = simulation_main.stop_watch.get_time() - _bagger_seek_start_sim_t
				b.is_available = false
				current_bagger = b
				_bagger_seek_start_sim_t = 0.0
				DebugLog.log_printer("[DIRT_TRUCK] id=%d BAGGER_FOUND | bagger_pos=%s | work_target=%s | seek_time=%.2fs" % [
					id, b.position, b.work_target, seek_time])
				return b.work_target
		# No bagger available yet — return zero (agent stays put). Throttled log.
		_no_bagger_log_throttle += 1
		if _no_bagger_log_throttle >= 120:
			_no_bagger_log_throttle = 0
			var wait_s: float = simulation_main.stop_watch.get_time() - _bagger_seek_start_sim_t
			DebugLog.log_printer("[DIRT_TRUCK] id=%d still waiting for bagger | seek_time=%.2fs" % [id, wait_s])
	elif current_state == WorkState.EXITING:
		return spawnpoint
	return Vector3.ZERO


func perform_work():
	if current_bagger && current_state == WorkState.WORKING:
		#DebugLog.log_printer("[DIRT_TRUCK] id=%d ARRIVED_AT_BAGGER | bagger=%s | load=%d/%d" % [
			#id, current_bagger.name, current_load_level, capacity])
		current_bagger.is_available = false
		current_bagger.dirt_truck = self
		is_being_loaded = true
		# Bagger already reached its cell and called perform_work() with no truck assigned.
		# Now that the truck is here, trigger it to start digging.
		current_bagger.perform_work()
	elif current_state == WorkState.EXITING:
		if !simulation_main.grid.is_construction_zone_excavated:
			# Arrived back at spawn — unload and go find another bagger
			#_round_trips_completed += 1
			#var trip_time: float = simulation_main.stop_watch.get_time() - _round_trip_start_sim_t
			#DebugLog.log_printer("[DIRT_TRUCK] id=%d UNLOADED_AT_SPAWN | round_trip=%d | trip_sim_time=%.2fs | load_was=%d" % [
				#id, _round_trips_completed, trip_time, current_load_level])
			_round_trip_start_sim_t = simulation_main.stop_watch.get_time()
			current_load_level = 0
			is_full = false
			is_being_loaded = false
			current_state = WorkState.WORKING
		else:
			#DebugLog.log_printer("[DIRT_TRUCK] id=%d EXITING_FINAL | round_trips=%d" % [id, _round_trips_completed])
			self.queue_free()
		has_reached_goal = false
		set_movement_target(get_target())

func load_truck():
	current_load_level += 1
	#DebugLog.log_printer("[DIRT_TRUCK] id=%d LOADED | level=%d/%d | is_full=%s" % [
		#id, current_load_level, capacity, str(current_load_level >= capacity)])

	if current_load_level >= capacity:
		is_full = true
		is_being_loaded = false
		current_bagger = null
		current_state = WorkState.EXITING
		#DebugLog.log_printer("[DIRT_TRUCK] id=%d FULL → heading to spawn | round_trip#%d" % [id, _round_trips_completed + 1])
		set_movement_target(get_target())
		has_reached_goal = false
