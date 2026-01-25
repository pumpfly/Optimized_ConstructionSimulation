extends Node3D

var heightmap_width

func _ready():
	# Check for the argument
	## Heightmap
	var heightmap_path = get_cmd_argument("--heightmap")
	
	if heightmap_path:
		print("Loading heightmap from: ", heightmap_path)
		
		var img = Image.new()
		var error = img.load(heightmap_path)
		if error != OK:
			printerr("Failed to load image at path: ", heightmap_path)
			return
		load_external_heightmap(img)
		find_spawn_point(img)
	else:
		print("No heightmap argument found")

# Helper function to find the value of a specific argument
func get_cmd_argument(argument_name: String) -> String:
	var args = OS.get_cmdline_args()
	
	# Iterate through the arguments
	for i in range(args.size()):
		# If we find the flag, and there is an argument after it...
		if args[i] == argument_name and i < args.size() - 1:
			return args[i + 1] # Return the next string (the file path)
			
	return "" # Return empty if not found

func load_external_heightmap(img: Image):
	# Heightmap dimensions
	var heightmap_img_width = img.get_width()
	var heightmap_img_height = img.get_height()
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
		collision_shape.position = Vector3(0.2, -20.2, -0.2) 
	else:
		printerr("⚠ CollisionShape3D not found or shape is not HeightMapShape3D")
		
	var navigation_region: NavigationRegion3D = $NavigationRegion3D
	if navigation_region:
		navigation_region.bake_navigation_mesh()
		navigation_region.navigation_mesh.cell_size = 2.0
		navigation_region.navigation_mesh.set_collision_mask_value(1, true)

func find_spawn_point(img: Image)-> Vector3:
	var bagger_scene: CharacterBody3D = $Bagger
	for i in range(img.get_width()):
		for j in range(img.get_height()):
			if img.get_pixel(i, j).g == 255:
				var spawnpoint: Vector3 = Vector3(i, 0, j)
				bagger_scene.position = spawnpoint
				return spawnpoint
			else:
				continue
	return Vector3(0,0,0)
	
	
