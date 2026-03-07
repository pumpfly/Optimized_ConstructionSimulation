class_name DirtTruck
extends BaseNavigation


var is_being_loaded = false

var is_full = false
var capacity: int = 8 # cells or cubic meters
var current_load_level: int = 0
var current_bagger: CharacterBody3D = null

enum WorkState{WORKING, EXITING}
var current_state = WorkState.WORKING

@onready var baggers = self.get_parent().get_parent().get_node("BaggerParent")
@onready var id = self.get_parent().get_child_count()

func _ready():
	super._ready()
	navigation_agent.radius = 1.0

func get_target() -> Vector3:
	#print("[Dirt Truck] %s" %id)
	if current_state == WorkState.WORKING:
		if current_bagger:
			return current_bagger.work_target
		for b: CharacterBody3D in baggers.get_children():
			if b.is_available:
				b.is_available = false
				current_bagger = b
				#print("assigned bagger: %s" %b.id)
				#print("assigned bagger position: %s" %b.position)
				return b.position
	elif current_state == WorkState.EXITING:
		return spawnpoint
	return Vector3.ZERO


func perform_work():
	if current_bagger && current_state == WorkState.WORKING:
		current_bagger.is_available = false
		current_bagger.dirt_truck = self
		is_being_loaded = true
		# Bagger already reached its cell and called perform_work() with no truck assigned.
		# Now that the truck is here, trigger it to start digging.
		current_bagger.perform_work()
	elif current_state == WorkState.EXITING:
		if !simulation_main.grid.is_construction_zone_excavated:
			# Arrived back at spawn — unload and go find another bagger
			current_load_level = 0
			is_full = false
			is_being_loaded = false
			current_state = WorkState.WORKING
		else:
			self.queue_free()
		has_reached_goal = false
		set_movement_target(get_target())

func load_truck():
	current_load_level += 1

	if current_load_level >= capacity:
		is_full = true
		is_being_loaded = false
		current_bagger = null
		current_state = WorkState.EXITING
		set_movement_target(get_target())
		has_reached_goal = false
