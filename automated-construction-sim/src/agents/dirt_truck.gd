class_name DirtTruck
extends BaseNavigation


var is_being_loaded = false

var is_full = false
var capacity: int = 8 # cells or cubic meters
var current_load_level: int = 0
var current_bagger: CharacterBody3D = null

enum WorkPhase{WORKING, EXITING}
var current_state = WorkPhase.WORKING

@onready var baggers = self.get_parent().get_parent().get_node("BaggerParent")

func get_target() -> Vector3:
	if current_state == WorkPhase.WORKING:
		if current_bagger: 
			return current_bagger.position
		for b: CharacterBody3D in baggers:
			if b.is_available:
				current_bagger = b
				return b.position
	elif current_state == WorkPhase.EXITING: 
		return spawnpoint
	return Vector3.ZERO


func perform_work():
	current_bagger.get_script().is_available = false
	current_bagger.get_script().dirt_truck = self
	

func load_truck():
	current_load_level += 1
	
	if current_load_level >= capacity:
		is_full = true
		current_bagger = null
		current_state = WorkPhase.EXITING
		set_movement_target(get_target())
		has_reached_goal = false
