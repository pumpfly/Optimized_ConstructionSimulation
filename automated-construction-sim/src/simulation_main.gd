extends Node3D

func _ready():
	# Check for the argument
	## Heightmap
	var heightmap_path = get_cmd_argument("--heightmap")
	## Simulation speed
	var simulation_speed = get_cmd_argument("--speed")
	
	if heightmap_path:
		var img = Image.new()
		var error = img.load(heightmap_path)
		if error != OK:
			printerr("Failed to load image at path: ", heightmap_path)
			return
		# Heightmap dimensions
		var heightmap_img_width = img.get_width()
		var heightmap_img_height = img.get_height()
		
		load_external_heightmap(img, heightmap_img_width, heightmap_img_height)
		find_spawn_point(img, heightmap_img_width, heightmap_img_height)
	else:
		print("No heightmap argument found")
	
	if simulation_speed:
		var speed: int = simulation_speed.to_int()
		Engine.time_scale = speed
		Engine.physics_ticks_per_second = 60*speed
	else:
		print("No speed argument found")

# Helper function to find the value of a specific argument
func get_cmd_argument(argument_name: String) -> String:
	var args = OS.get_cmdline_args()
	
	# Iterate through the arguments
	for i in range(args.size()):
		# If we find the flag, and there is an argument after it...
		if args[i] == argument_name and i < args.size() - 1:
			return args[i + 1] # Return the next string (the file path)
			
	return "" # Return empty if not found

func load_external_heightmap(img: Image, heightmap_img_width: int, heightmap_img_height: int):
	
	#Create a heightmap from the Image
	var heightmap = ImageTexture.create_from_image(img)
	
	# Creating new Plane and set size
	var plane_mesh: PlaneMesh = PlaneMesh.new()
	plane_mesh.size = Vector2(heightmap_img_width, heightmap_img_height)
	plane_mesh.subdivide_width = heightmap_img_width-1
	plane_mesh.subdivide_depth = heightmap_img_height-1
	
	# Creating ShaderMaterial and load displacement shader
	var shader_material = ShaderMaterial.new()
	var displacement_shader = ResourceLoader.load("res://Shader/displacementShader.gdshader")
	shader_material.shader = displacement_shader
	shader_material.set_shader_parameter("heightmap", heightmap)
	shader_material.set_shader_parameter("height_scale", 255.0)
	# Color range for gradient visualization - adjust based on your heightmap
	shader_material.set_shader_parameter("color_min", 0.0)
	shader_material.set_shader_parameter("color_max", 0.3)  # Adjust this value

	# Apply heightmap to mesh shader
	var mesh_instance: MeshInstance3D = $MeshInstance3D
	if mesh_instance:
		#set position
		mesh_instance.position = Vector3(0.0, -20.0, 0.0)
		# Set plane as mesh
		mesh_instance.mesh = plane_mesh
		# Assign material to mesh
		mesh_instance.set_surface_override_material(0, shader_material)
	else:
		printerr("⚠ MeshInstance3D not found!")
		
	# Apply heightmap to collision shape
	var collision_shape: CollisionShape3D = $NavigationRegion3D/StaticBody3D/CollisionShape3D
	if collision_shape and collision_shape.shape is HeightMapShape3D:
		# Convert image to proper format for HeightMapShape3D
		var hm_image = img.duplicate()
		hm_image.convert(Image.FORMAT_RF)
		# Update the heightmap shape
		collision_shape.shape.update_map_data_from_image(hm_image, 0.0, 255.0)
		collision_shape.scale = Vector3(1.01, 1.01, 1.01)
		collision_shape.position = Vector3(0.2, -19, -0.2) 
	else:
		printerr("⚠ CollisionShape3D not found or shape is not HeightMapShape3D")
		
	var navigation_region: NavigationRegion3D = $NavigationRegion3D
	if navigation_region:
		navigation_region.bake_navigation_mesh()
		navigation_region.navigation_mesh.cell_size = 2.0
		navigation_region.navigation_mesh.set_collision_mask_value(1, true)
		collision_shape.disabled = true

func find_spawn_point(img: Image, heightmap_width: int , heightmap_height: int)-> Vector3:
	for i in range(img.get_width()):
		for j in range(img.get_height()):
			if img.get_pixel(i, j).g >= 0.9:
				var spawnpoint: Vector3 = Vector3(i - heightmap_width/2, 2, j - heightmap_height/2)
				return spawnpoint
			else:
				continue
	return Vector3(0,0,0)
	
	
