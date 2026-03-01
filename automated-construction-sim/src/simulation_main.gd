class_name SimulationMain
extends Node3D

@onready var terrain: Terrain = %Terrain
@onready var agent_spawner: AgentSpawner = %AgentSpawner
@onready var stop_watch: Node = %StopWatch

var img: Image = null
var grid: Grid = null

var agent_schedule: Dictionary = {}

signal construction_finished
var _construction_finished_emitted: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Check for the argument
	## Heightmap
	var heightmap_path = _get_cmd_argument("--heightmap")
	## Simulation speed
	var simulation_speed = _get_cmd_argument("--speed")

	img = _get_heightmap_image(heightmap_path)
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
	grid = Grid.new(img)
	agent_spawner.grid = grid
	agent_spawner.spawnpoint = Vector3(grid.get_spawn_cell().world_pos.x, 0, grid.get_spawn_cell().world_pos.z)
	agent_spawner.agent_schedule = agent_schedule

	if simulation_speed:
		var speed: int = simulation_speed.to_int()
		Engine.time_scale = speed
		Engine.physics_ticks_per_second = 60 * speed
	else:
		print("No speed argument found")


#func _process(_delta: float) -> void:
	#if grid and grid.is_construction_zone_excavated and not _construction_finished_emitted:
		#_construction_finished_emitted = true
		#construction_finished.emit()


func _get_heightmap_image(heightmap_path: String) -> Image:
	var curr_img = Image.new()
	if heightmap_path:
		var error = curr_img.load(heightmap_path)
		if error != OK:
			printerr("Failed to load image at path: ", heightmap_path)
			return
	else:
		print("No heightmap argument found")
	return curr_img


# Helper function to find the value of a specific argument
func _get_cmd_argument(argument_name: String) -> String:
	var args = OS.get_cmdline_args()

	# Iterate through the arguments
	for i in range(args.size()):
		# If we find the flag, and there is an argument after it...
		if args[i] == argument_name and i < args.size() - 1:
			return args[i + 1] # Return the next string (the file path)

	return "" # Return empty if not found


func set_heightmap_depth_by_pixel(height_increment: float, x: int, y: int):
	@warning_ignore("narrowing_conversion")
	var current_pixel_color = img.get_pixel(x, y)
	@warning_ignore("narrowing_conversion")
	#print("Current color: %s" %current_pixel_color.r)
	current_pixel_color.r -= height_increment
	#print("Edited color: %s" %current_pixel_color.r)
	img.set_pixel(x, y, current_pixel_color)
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
