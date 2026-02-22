class_name Grid
extends RefCounted

var grid: Array[Array] = []
var grid_width: int = 0
var grid_height: int = 0

var spawn_cell: Cell = null
var construction_zone: Array[Cell] = []

# Track construction zone completion efficiently
var completed_construction_cells: int = 0
var is_construction_complete: bool = false

# Constructor - creates the grid from heightmap data -> amount of cells allign with pixel count
func _init(heightmap: Image):
	grid_width = heightmap.get_width()
	grid_height = heightmap.get_height()
	
	grid.resize(grid_width)
	
	for x in range(grid_width):
		grid[x] = []
		grid[x].resize(grid_height)
		
		for y in range(grid_height):
			# Get height from heightmap
			var pixel_color = heightmap.get_pixel(x, y)
			var height = int(pixel_color.r * 255.0)
		
			# Calculate world position (centered grid)
			@warning_ignore("integer_division")
			var world_pos = Vector3(x - grid_width/2, height, y - grid_height/2)
		
			# Create cell using _init()
			grid[x][y] = Cell.new(x, y, world_pos, height)
			
	construction_zone = find_construction_cells(heightmap)
	spawn_cell = find_spawn_cell(heightmap)


func get_cell(x: int, y: int) -> Cell:
	if x >= 0 and x < grid_width and y >= 0 and y < grid_height:
		return grid[x][y]
	return null


func get_cell_neighbors(cell: Cell) -> Array[Cell]:
	#   __ __ __
	#  |__|__|__|
	#  |__|CL|__|
	#  |__|__|__|
	var neighbors: Array[Cell] = []
	
	var offset: Array[Vector2i] = [
		Vector2i(-1, 1),
		Vector2i(-1, 0),
		Vector2i(-1, -1),
		Vector2i(0, -1),
		Vector2i(1, -1),
		Vector2i(1, 0),
		Vector2i(1, 1),
		Vector2i(0, 1)
	]
	
	for o in offset:
		var neighbor: Cell
		var neighborIndex: Vector2i = Vector2i(cell.grid_x + o.x, cell.grid_y + o.y)
		# Check if out of bounds
		if neighborIndex.x >= grid_width || neighborIndex.y >= grid_width || neighborIndex.x < 0 || neighborIndex.y < 0:
			continue
		else:
			neighbor = grid[neighborIndex.x][neighborIndex.y]
			neighbors.append(neighbor)
	
	return neighbors


func world_pos_to_cell_index(world_position: Vector3) -> Vector2i:
	var cell_x: int = (int)(world_position.x / 2);
	var cell_y: int = (int)(world_position.z / 2);
	var cell_index: Vector2i = Vector2i(cell_x, cell_y)
	return cell_index


func get_cell_at_world_pos(world_position: Vector3) -> Cell:
	var grid_coords = world_pos_to_cell_index(world_position)
	return get_cell(grid_coords.x, grid_coords.y)


# Find the nearest available cell to a position
func find_nearest_available_cell(world_position: Vector3) -> Cell:
	var start_coords = world_pos_to_cell_index(world_position)
	
	# Spiral search outward from the starting position
	var max_search_radius = 20
	for radius in range(max_search_radius):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				# Only check cells at current radius (not interior)
				if abs(dx) == radius or abs(dy) == radius:
					var check_x = start_coords.x + dx
					var check_y = start_coords.y + dy
					var cell = get_cell(check_x, check_y)
					if cell and cell.is_available():
						return cell
	return null

# find and return all cells on the construction zone
# The construction zone can be seen on the heightmap as the pure blue area
func find_construction_cells(heightmap: Image) -> Array[Cell]:
	var construction_cells: Array[Cell] = []
	var cell: Cell

	for x in range(grid_width):
		for y in range(grid_height):
			var pixel_color = heightmap.get_pixel(x, y)
			if pixel_color.b >= 0.9:
				cell = grid[x][y]
				cell.is_construction_zone_cell = true
				construction_cells.append(cell)

	return construction_cells
	
func get_construction_zone() -> Array[Cell]:
	return construction_zone


# The green pixel on the heightmap is the spawn point or spawn cell, this is where all agents first appear
func find_spawn_cell(heightmap: Image) -> Cell:
	for x in range(grid_width):
		for y in range(grid_height):
			if heightmap.get_pixel(x, y).g > 0.9:
				return grid[x][y]
	return null


func get_spawn_cell() -> Cell:
	return spawn_cell

# Called when a construction zone cell's state is changed to COMPLETED
# Updates the counter and checks if all construction is done
func on_construction_cell_completed() -> void:
	completed_construction_cells += 1
	
	# Check if all construction zone cells are now completed
	if completed_construction_cells >= construction_zone.size():
		is_construction_complete = true

# Check if construction zone is fully excavated
func is_construction_zone_complete() -> bool:
	return is_construction_complete

# DEBUGING: Get statistics about grid state
#func get_grid_stats() -> Dictionary:
	#var stats = {
		#"total_cells": grid_width * grid_height,
		#"occupied_cells": 0,
		#"completed_cells": 0,
		#"assigned_cells": 0
	#}
#
	#for x in range(grid_width):
		#for y in range(grid_height):
			#var cell = grid[x][y]
			#if cell.is_occupied:
				#stats["occupied_cells"] += 1
			#if cell.current_state == Cell.WorkState.COMPLETED:
				#stats["completed_cells"] += 1
			#if cell.current_state == Cell.WorkState.ASSIGNED:
				#stats["assigned_cells"] += 1
#
	#return stats
