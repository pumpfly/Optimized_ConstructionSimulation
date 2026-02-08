class_name AgentSpawner
extends Node

var spawnpoint: Vector3
var time:int

@onready var bagger: PackedScene = preload("res://Scenes/Bagger.scn")

func _process(delta: float) -> void:
	time = %StopWatch.get_time()

func create_agents(agent_schedule: Dictionary):
	#TODO: Make Scenes of the other Agents aswell and instantiate them here
	if agent_schedule[time]:
		for agent_type in agent_schedule[time]:
			if agent_type == "Bagger":
				var bagger_instance = bagger.instantiate()
				add_child(bagger_instance)
