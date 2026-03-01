class_name Crane
extends BaseNavigation

func _ready():
	super._ready()
	navigation_agent.radius = 15.0

func get_target() -> Vector3:
	return Vector3.ZERO

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
