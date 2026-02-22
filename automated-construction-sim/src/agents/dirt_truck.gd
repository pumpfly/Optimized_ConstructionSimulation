class_name DirtTruck
extends BaseNavigation

# The dirt truck has to navigate to a cell that is somewaht close to the construction_zone
# for that I will calculate the radius of the construction_zone and the dirt truck will choose a random cell slightly further than the radius

# The trucks also have to keep track on what cell is occupied and have to register the cell they occupy
# 

var is_being_loaded = false
var is_full = false
var capacity: int = 8 # cells or cubic meters
var current_load_level: int = 0

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
