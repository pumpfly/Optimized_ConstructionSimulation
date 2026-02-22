class_name SimulationMain
extends Node3D

@onready var terrain: Terrain = %Terrain
@onready var agent_spawner: AgentSpawner = %AgentSpawner

var img: Image = null
var grid: Grid = null

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
	
	# Setting spawn and navigation points
	#agent_spawner.spawnpoint = find_spawn_point(img.get_width(), img.get_height())
	#agent_spawner.construction_zone = find_construction_area(img.get_width(), img.get_height())
	
	if simulation_speed:
		var speed: int = simulation_speed.to_int()
		Engine.time_scale = speed
		Engine.physics_ticks_per_second = 60*speed
	else:
		print("No speed argument found")


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

#func find_spawn_point(heightmap_width: int , heightmap_height: int)-> Vector3:
	#for i in range(img.get_width()):
		#for j in range(img.get_height()):
			#if img.get_pixel(i, j).g >= 0.9:
				#@warning_ignore("integer_division")
				#var spawnpoint: Vector3 = Vector3(i - heightmap_width/2, 2, j - heightmap_height/2)
				#return spawnpoint
			#else:
				#continue
	#return Vector3(0,0,0)

#func find_construction_area(heightmap_width: int , heightmap_height: int)-> Array[Vector3]:
	#var construction_area: Array[Vector3] = []
	#for i in range(img.get_width()):
		#for j in range(img.get_height()):
			#if img.get_pixel(i, j).b >= 0.9:
				#@warning_ignore("integer_division")
				#var c_area_point: Vector3 = Vector3(i - heightmap_width/2, 2, j - heightmap_height/2)
				#construction_area.append(c_area_point)
			#else:
				#continue
	#return construction_area
	

func set_heightmap_depth_by_pixel(height_increment: int, x: int, y: int):
	@warning_ignore("narrowing_conversion")
	var current_pixel_color = img.get_pixel(x, y)
	@warning_ignore("narrowing_conversion")
	img.set_pixel(x, y, current_pixel_color - height_increment)
	terrain.build_terrain_with_heightmap(img, img.get_width(), img.get_height())
	
