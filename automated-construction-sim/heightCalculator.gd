@tool
extends CollisionShape3D

@export var min_height = 0.0:
	set(new_min_height): 
		min_height = new_min_height
		update_map_data()
@export var max_height = 5.0: #TODO: height should be taken from the planes meshInstance3d
	set(new_max_height): 
		max_height = new_max_height
		update_map_data()

@export var heightmap = ResourceLoader.load("res://Heightmaps/28_179_86_691_15_505_505_16bit.png")
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	update_map_data()
	pass

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
	
func update_map_data() -> void:
	var hmImage = heightmap.get_image()
	hmImage.convert(Image.FORMAT_RF)
	shape.update_map_data_from_image(hmImage, min_height, max_height)
	#shape.owner = self
