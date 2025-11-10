# res://Agent.gd
extends CharacterBody3D

@export var speed: float = 6.0
@export var gene_duration: float = 0.2
@export var max_sim_time: float = 10.0

var genome:= []  # Array von ints
var gene_index: int = 0
var gene_time_acc: float = 0.0
var sim_time: float = 0.0
var finished: bool = false


# Typisierte ACTIONS-Liste: Godot weiß jetzt, dass es Vector2-Elemente sind.
static var ACTIONS: Array[Vector2] = [
	Vector2(0, 0),                 # 0 = do nothing
	Vector2(0, -1),                # 1 = North (negative Z)
	Vector2(1, -1).normalized(),   # 2 = NE
	Vector2(1, 0),                 # 3 = East
	Vector2(1, 1).normalized(),    # 4 = SE
	Vector2(0, 1),                 # 5 = South
	Vector2(-1, 1).normalized(),   # 6 = SW
	Vector2(-1, 0),                # 7 = West
	Vector2(-1, -1).normalized()   # 8 = NW
]

func reset_for_run() -> void:
	velocity = Vector3.ZERO
	gene_index = 0
	gene_time_acc = 0.0
	sim_time = 0.0
	finished = false

func set_genome(g) -> void:
	genome = g.duplicate(true)

func _physics_process(delta: float) -> void:
	if finished:
		return

	sim_time += delta
	if sim_time >= max_sim_time:
		finished = true
		return

	gene_time_acc += delta
	while gene_time_acc >= gene_duration:
		gene_time_acc -= gene_duration
		gene_index += 1
		if gene_index >= genome.size():
			gene_index = genome.size() - 1

	# typisierte Lese- und Zwischenvariablen vermeiden Variant-Fallback
	var raw_index: int = genome[clamp(gene_index, 0, genome.size() - 1)]
	var action_index: int = clamp(raw_index, 0, ACTIONS.size() - 1)
	var dir2: Vector2 = ACTIONS[action_index]
	var move_dir: Vector3 = Vector3(dir2.x, 0.0, dir2.y)

	if move_dir.length() > 0.0:
		move_dir = move_dir.normalized()
		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
	else:
		velocity.x = lerp(velocity.x, 0.0, 0.2)
		velocity.z = lerp(velocity.z, 0.0, 0.2)

	# gravity
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	else:
		velocity.y = 0.0

	move_and_slide()
