class_name Stopwatch
extends Node

var time: float = 0.0
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	time += delta
	
func get_time() -> float:
	return time
