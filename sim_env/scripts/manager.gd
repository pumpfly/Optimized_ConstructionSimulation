extends Node3D
#godot --headless --disable-render-loop --path bauablaufoptimierung

@export var AgentScene: PackedScene
@export var population_size: int = 40
@export var sim_time: float = 10.0
@export var sim_speed: float = 1.0
@export var gene_duration: float = 0.2
@export var elitism_count: int = 2
@export var tournament_k: int = 3
@export var crossover_rate: float = 0.9
@export var mutation_rate: float = 0.02
@export var max_generations: int = 200

@onready var target: Node3D = $"../Target"



var genes_count: int
var genomes: Array = []        # enthält Arrays von int (jedes Element ist ein Genome = Array[int])
var population: Array = []     # enthält instanzen (CharacterBody3D)
var fitnesses: Array = []      # Array[float]
var generation: int = 0

func _ready() -> void:
	Engine.time_scale = sim_speed
	genes_count = int(ceil(sim_time / gene_duration))
	randomize()
	_init_population()
	_start_generation()

func _init_population() -> void:
	genomes.clear()
	for i in range(population_size):
		genomes.append(_random_genome())

func _random_genome() -> Array[int]:
	var g: Array[int] = []
	for i in range(genes_count):
		g.append(randi() % 9) # Aktionen 0..8
	return g

func _spawn_population() -> void:
	# free existing instances (oder poolen)
	for a_index in range(population.size()):
		var a_inst: Node3D = population[a_index]
		if is_instance_valid(a_inst):
			a_inst.queue_free()
	population.clear()
	fitnesses.clear()

	for i in range(population_size):
		var inst: CharacterBody3D = AgentScene.instantiate() as CharacterBody3D
		add_child(inst)
		# Positionsgitter zum Spawn
		inst.global_transform.origin = global_transform.origin + Vector3(0, 1.0, 0)

		inst.reset_for_run()
		inst.set_genome(genomes[i] as Array[int])
		
		population.append(inst)
		fitnesses.append(-INF)

func _start_generation() -> void:
	generation += 1
	print("=== Generation %d ===" % generation)
	_spawn_population()
	var t: Timer = Timer.new()
	t.one_shot = true
	t.wait_time = sim_time + 0.05
	add_child(t)
	t.start()
	t.timeout.connect(_on_simulation_timeout)

func _on_simulation_timeout() -> void:
	_evaluate_population()
	if generation >= max_generations:
		print("Reached max generations. Best fitness:", _get_best_fitness())
		return
	_evolve_population()
	_start_generation()

func _evaluate_population() -> void:
	for i in range(population.size()):
		var a_node: Node3D = population[i]
		var a: CharacterBody3D = a_node as CharacterBody3D
		if not is_instance_valid(a):
			fitnesses[i] = -1e9
			continue
		var dist: float = a.global_transform.origin.distance_to(target.global_transform.origin)
		var bonus: float = 0.0
		if dist < 1.0:
			bonus = 1000.0
		fitnesses[i] = -dist + bonus
	var best_idx: int = _argmax(fitnesses)
	if best_idx >= 0 and best_idx < fitnesses.size():
		print("Best fitness:", (50.4 + fitnesses[best_idx])*100/50.4, " idx:", best_idx)

func _evolve_population() -> void:
	var new_genomes: Array = []
	var sorted_idx: Array = _argsort_desc_simple(fitnesses)
	for i in range(min(elitism_count, sorted_idx.size())):
		new_genomes.append(genomes[sorted_idx[i]].duplicate(true) as Array[int])
	while new_genomes.size() < population_size:
		var pa: Array = _tournament_selection()
		var pb: Array = _tournament_selection()
		var child: Array = pa.duplicate(true)
		if randf() < crossover_rate:
			child = _crossover(pa, pb)
		_mutate(child)
		new_genomes.append(child as Array[int])
	genomes = new_genomes

func _tournament_selection() -> Array:
	var best_idx: int = -1
	var best_fit: float = -INF
	for k in range(tournament_k):
		var idx: int = randi() % population_size
		if fitnesses[idx] > best_fit:
			best_fit = fitnesses[idx]
			best_idx = idx
	return genomes[best_idx]

func _crossover(a: Array, b: Array) -> Array:
	var child: Array = []
	var point: int = randi() % a.size()
	for i in range(a.size()):
		child.append(a[i] if i < point else b[i])
	return child

func _mutate(g: Array) -> void:
	for i in range(g.size()):
		if randf() < mutation_rate:
			g[i] = randi() % 9

# Hilfsfunktionen
func _argmax(arr: Array) -> int:
	if arr.is_empty():
		return -1
	var best_i: int = 0
	var best_v: float = -INF
	for i in range(arr.size()):
		var v: float = arr[i]
		if v > best_v:
			best_v = v
			best_i = i
	return best_i

func _argsort_desc_simple(arr: Array) -> Array:
	var idx: Array = []
	for i in range(arr.size()):
		idx.append(i)
	for i in range(idx.size()):
		for j in range(i+1, idx.size()):
			var lhs_idx: int = idx[j]
			var rhs_idx: int = idx[i]
			if arr[lhs_idx] > arr[rhs_idx]:
				var tmp: int = idx[i]
				idx[i] = idx[j]
				idx[j] = tmp
	return idx

func _get_best_fitness() -> float:
	if fitnesses.is_empty():
		return -INF
	var i: int = _argmax(fitnesses)
	return fitnesses[i]
