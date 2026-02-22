class_name DirtTruck
extends BaseNavigation


var is_being_loaded = false
var is_full = false
var capacity: int = 8 # cells or cubic meters
var current_load_level: int = 0

@onready var baggers = self.get_parent().get_parent().get_node("BaggerParent")

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func get_target() -> Vector3:
	for b: Bagger in baggers:
		if b.is_available:
			return b.position
	return Vector3.ZERO
