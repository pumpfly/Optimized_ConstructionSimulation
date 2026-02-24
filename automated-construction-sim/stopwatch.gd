class_name Stopwatch
extends Node

var time: float = 0.0
signal timeout

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	time += delta
	signal_timeout()
	
func get_time() -> float:
	return time

func signal_timeout():
	if time == 7200:
		timeout.emit() 
