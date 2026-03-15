class_name SimulationMain
extends Node3D

@onready var terrain: Terrain = %Terrain
@onready var agent_spawner: AgentSpawner = %AgentSpawner
@onready var stop_watch: Node = %StopWatch

var img: Image = null
var grid: Grid = null

var agent_schedule: Dictionary = {}

signal construction_finished

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Check for the argument
	## Heightmap
	var heightmap_path = _get_cmd_argument("--heightmap")
	## Simulation speed
	var simulation_speed = _get_cmd_argument("--speed")

	# --- Startup performance ---
	var t0 := DebugLog.start_perf()

	img = _get_heightmap_image(heightmap_path)

	var t_terrain := DebugLog.start_perf()
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
	DebugLog.end_perf("terrain.build_terrain_with_heightmap (%dx%d)" % [img.get_width(), img.get_height()], t_terrain)

	var t_grid := DebugLog.start_perf()
	grid = Grid.new(img)
	DebugLog.end_perf("Grid.new (%d cells, %d cc-zone, %d pipe-cells)" % [
		grid.grid_width * grid.grid_height,
		grid.construction_zone.size(),
		grid.pipe_placement_cells.size()], t_grid)

	agent_spawner.grid = grid
	agent_spawner.spawnpoint = Vector3(grid.get_spawn_cell().world_pos.x, 0, grid.get_spawn_cell().world_pos.z)
	agent_spawner.agent_schedule = agent_schedule

	if simulation_speed:
		var speed: int = simulation_speed.to_int()
		Engine.time_scale = speed
		Engine.physics_ticks_per_second = 60 * speed
		DebugLog.log_printer("[SIM_MAIN] Speed=%dx | time_scale=%d" % [speed, Engine.time_scale])
	else:
		DebugLog.log_printer("[SIM_MAIN] No speed argument — running at 1x (time_scale=1)")
		print("No speed argument found")

	DebugLog.end_perf("SimulationMain._ready total", t0)


func _get_heightmap_image(heightmap_path: String) -> Image:
	var curr_img = Image.new()
	if heightmap_path:
		var t := DebugLog.start_perf()
		var error = curr_img.load(heightmap_path)
		DebugLog.end_perf("Image.load(%s)" % heightmap_path, t)
		if error != OK:
			printerr("Failed to load image at path: ", heightmap_path)
			return
	else:
		DebugLog.log_printer("[SIM_MAIN] No heightmap argument found")
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


var _terrain_rebuild_count: int = 0
var _terrain_rebuild_total_us: int = 0

func set_heightmap_depth_by_pixel(height_increment: float, x: int, y: int):
	@warning_ignore("narrowing_conversion")
	var current_pixel_color = img.get_pixel(x, y)
	@warning_ignore("narrowing_conversion")
	current_pixel_color.r -= height_increment
	img.set_pixel(x, y, current_pixel_color)

	# Measure every terrain rebuild — this is called once per completed cell
	var t := DebugLog.start_perf()
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
	var us := Time.get_ticks_usec() - t

	_terrain_rebuild_count += 1
	_terrain_rebuild_total_us += us

	# Log every rebuild and a running average every 10
	DebugLog.log_printer("[TERRAIN_REBUILD] #%d | %.3fms | running_avg=%.3fms" % [
		_terrain_rebuild_count, us / 1000.0,
		(_terrain_rebuild_total_us / _terrain_rebuild_count) / 1000.0])

func update_terrain():
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
