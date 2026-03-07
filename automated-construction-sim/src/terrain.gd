class_name Terrain
extends Node3D

func build_terrain_with_heightmap(img: Image, heightmap_img_width: int, heightmap_img_height: int):
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
	# Declared here so it is accessible after the bake for the disable step
	var collision_shape: CollisionShape3D = $NavigationRegion3D/StaticBody3D/CollisionShape3D
	if collision_shape and collision_shape.shape is HeightMapShape3D:
		# Convert image to proper format for HeightMapShape3D
		var hm_image = img.duplicate()
		hm_image.convert(Image.FORMAT_RF)
		# Update the heightmap shape
		collision_shape.shape.update_map_data_from_image(hm_image, 0.0, 255.0)
		collision_shape.scale = Vector3(1.01, 1.01, 1.01)
		collision_shape.position = Vector3(0.2, -19.9, -0.2)
		# Leave enabled here — the navmesh bake below needs it as source geometry
	else:
		printerr("⚠ CollisionShape3D not found or shape is not HeightMapShape3D")

	var navigation_region: NavigationRegion3D = $NavigationRegion3D
	if navigation_region:
		# Settings must be applied BEFORE baking — changes after the bake have no effect
		navigation_region.navigation_mesh.cell_size = 0.3
		navigation_region.navigation_mesh.agent_radius = 0.6  # must be a multiple of cell_size (2 * 0.3)
		navigation_region.navigation_mesh.agent_max_slope = 50.0
		navigation_region.navigation_mesh.agent_max_climb = 50.0
		navigation_region.navigation_mesh.set_collision_mask_value(1, true)
		NavigationServer3D.map_set_cell_size(navigation_region.get_navigation_map(), 0.3)
		# Re-enable before baking: on subsequent calls (e.g. after cell excavation) the shape
		# was left disabled from the previous bake, so baking would find no source geometry.
		if collision_shape:
			collision_shape.disabled = false
		# Bake synchronously (false) so the navmesh is ready before any agent tries to navigate
		navigation_region.bake_navigation_mesh(false)
		# Disable only after baking — the bake uses the collision shape as source geometry
		if collision_shape:
			collision_shape.disabled = true
