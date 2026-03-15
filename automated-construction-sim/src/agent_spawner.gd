class_name AgentSpawner
extends Node

signal excavation_phase_complete

var agent_schedule: Dictionary = {}
var _excavation_signal_emitted: bool = false

@onready var bagger: PackedScene = preload("res://Scenes/Bagger.scn")
@onready var dirt_truck: PackedScene = preload("res://Scenes/Truck.scn")
@onready var material_truck: PackedScene = preload("res://Scenes/TruckWithMaterial.scn")
@onready var crane: PackedScene = preload("res://Scenes/Crane.scn")
@onready var pipe: PackedScene = preload("res://Scenes/pipe.tscn")

@onready var bagger_parent: Node = $BaggerParent
@onready var dirt_truck_parent: Node = $DirtTruckParent
@onready var crane_parent: Node = $CraneParent
@onready var material_truck_parent: Node = $MaterialTruckParent

var grid: Grid
var spawnpoint: Vector3

func _process(_delta: float) -> void:
	if grid == null:
		return
	var t: int = int(%StopWatch.get_time())
	create_agents(agent_schedule, t)
	if !_excavation_signal_emitted && bagger_parent.get_child_count() == 0 && dirt_truck_parent.get_child_count() == 0 && grid.is_construction_zone_excavated:
		DebugLog.log_printer("[PHASE] excavation_phase_complete | baggers=0 dirt_trucks=0 | cc_zone_done=true")
		excavation_phase_complete.emit()
		_excavation_signal_emitted = true

func create_agents(schedule: Dictionary, t: int) -> void:
	# Collect all overdue keys (key <= t). At high time_scale frames skip many seconds,
	# so a simple schedule.has(t) exact-match would miss most entries.
	var due_keys: Array = []
	for key in schedule.keys():
		if key <= t:
			due_keys.append(key)
	if due_keys.is_empty():
		return

	for key in due_keys:
		for agent_type in schedule[key]:
			if agent_type == "Bagger":
				var bagger_instance = bagger.instantiate()
				bagger_instance.position = spawnpoint
				bagger_parent.add_child(bagger_instance)
				DebugLog.log_printer("[SPAWN] Bagger | scheduled_t=%d | sim_t=%d | total_baggers=%d" % [key, t, bagger_parent.get_child_count()])
			if agent_type == "DirtTruck":
				var dirt_truck_instance = dirt_truck.instantiate()
				dirt_truck_instance.position = spawnpoint
				dirt_truck_parent.add_child(dirt_truck_instance)
				DebugLog.log_printer("[SPAWN] DirtTruck | scheduled_t=%d | sim_t=%d | total_dirt_trucks=%d" % [key, t, dirt_truck_parent.get_child_count()])
			if agent_type == "MaterialTruck":
				var material_truck_instance = material_truck.instantiate()
				material_truck_instance.position = spawnpoint
				material_truck_instance.crane_parent = crane_parent
				material_truck_parent.add_child(material_truck_instance)
				DebugLog.log_printer("[SPAWN] MaterialTruck | scheduled_t=%d | sim_t=%d | total_material_trucks=%d" % [key, t, material_truck_parent.get_child_count()])
			if agent_type == "Crane":
				var crane_instance = crane.instantiate()
				crane_instance.position = spawnpoint
				crane_instance.pipe = pipe
				crane_parent.add_child(crane_instance)
				excavation_phase_complete.connect(crane_instance.on_excavation_complete)
				DebugLog.log_printer("[SPAWN] Crane | scheduled_t=%d | sim_t=%d | total_cranes=%d" % [key, t, crane_parent.get_child_count()])
		# Erase after spawning so entries aren't re-processed next frame
		schedule.erase(key)
