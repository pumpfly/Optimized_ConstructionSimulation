class_name AgentSpawner
extends Node


var time:int

@onready var bagger: PackedScene = preload("res://Scenes/Bagger.scn")
@onready var dirt_truck: PackedScene = preload("res://Scenes/Truck.scn")
@onready var material_truck: PackedScene = preload("res://Scenes/Truck.scn")
@onready var crane: PackedScene = preload("res://Scenes/Crane.scn")

@onready var bagger_parent: Node = $BaggerParent
@onready var dirt_truck_parent: Node = $DirtTruckParent
@onready var crane_parent: Node = $CraneParent
@onready var material_truck_parent: Node = $MaterialTruckParent

var grid: Grid
var spawnpoint: Vector3

func _process(_delta: float) -> void:
	time = %StopWatch.get_time()

func create_agents(agent_schedule: Dictionary):
	if agent_schedule[time]:
		for agent_type in agent_schedule[time]:
			if agent_type == "Bagger":
				var bagger_instance = bagger.instantiate()
				bagger_instance.position = spawnpoint
				bagger_instance.grid = grid
				bagger_parent.add_child(bagger_instance)
			if agent_type == "DirtTruck":
				var dirt_truck_instance = dirt_truck.instantiate()
				dirt_truck_instance.position = spawnpoint
				dirt_truck_instance.grid = grid
				dirt_truck_parent.add_child(dirt_truck_instance)
			if agent_type == "MaterialTruck":
				var material_truck_instance = material_truck.instantiate()
				material_truck_instance.position = spawnpoint
				material_truck_instance.grid = grid
				crane_parent.add_child(material_truck_instance)
			if agent_type == "Crane":
				var crane_instance = crane.instantiate()
				crane_instance.position = spawnpoint
				crane_instance.grid = grid
				material_truck_parent.add_child(crane_instance)
