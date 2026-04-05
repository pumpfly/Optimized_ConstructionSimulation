// Genetic Algorithm Orchestrator for the Construction Simulation
//
// GA lifecycle:
//  1. Initialise a random population of populationSize individualividuals.
//  2. Encode each individualividual as a schedule and enqueue it.
//  3. Workers poll GET /work:
//     - Task available                 → JSON WorkData
//     - Queue empty but gen incomplete → "wait"
//     - All generations done           → "end"
//  4. Workers POST /handover?id=<id> with a Metrics JSON body.
//  5. When all results for the current generation are collected, evolve:
//     a. Compute fitness (lower time = better).
//     b. Select parents via tournament selection.
//     c. Produce offspring via uniform crossover + Gaussian mutation.
//     d. Elitism: carry the best eliteCount individualividuals unchanged.
//     e. Log generation statistics and save best schedule to disk.
//     f. Increment generation counter and re-fill the task queue.
//  6. After maxGenerations, mark finished; workers receive "end".
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const (
	defaultAddr  = "127.0.0.1:7050"
	outputDir    = "ga_results"
	maxSimTime   = 54000 // 15 hours in simulated seconds
	minSpawnTime = 1
	maxSpawnTime = maxSimTime / 2

	minExcavators     = 1
	maxExcavators     = 15
	minDirtTrucks     = 1
	maxDirtTrucks     = 15
	minMaterialTrucks = 1
	maxMaterialTrucks = 10
	craneCount        = 1 // fixed number

	tournamentSize       = 4
	crossoverProbability = 0.85
	mutationRate         = 0.05   // Mutation for the schedule
	mutationSigma        = 2160.0 // initial standard deviation for gaussian noise
	countMutationRate    = 0.1    // Mutation for the agents count
	eliteCount           = 2

	// Adaptive sigma parameters
	mutationSigmaMin  = 300.0   // ~5 min in sim-seconds; floor for exploration
	mutationSigmaMax  = 10800.0 // 3 h in sim-seconds; ceiling to avoid chaos
	sigmaGrowFactor   = 1.3     // multiply sigma when stagnating
	sigmaShrinkFactor = 0.9     // multiply sigma when improving
	stagnationWindow  = 5       // consecutive generations without improvement → stagnate

	// Equal to the maximum simulation time so timeout runs rank worst.
	timeoutPenalty = float64(maxSimTime)
)

// testSchedule is a debugging schedule
// Swap schedule inside getNextTask's.
// var testSchedule = map[string][]string{
// 	"1": {"excavator",
// 		"excavator",
// 		"excavator",
// 		"excavator",
// 		"excavator",
// 		"excavator",
// 		"excavator",
// 		"excavator",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"dirt_truck",
// 		"material_truck"},
// 	"153":  {"dirt_truck"},
// 	"4026": {"crane"},
// 	"468":  {"excavator"},
// 	"58":   {"excavator"},
// 	"66":   {"dirt_truck"},
// 	"7331": {"dirt_truck"},
// }

// ---------------------------------------------------------------------------
// Individuals
// ---------------------------------------------------------------------------

// Individual encodes a complete agent-spawn schedule.
// Fitness is nil until the simulation has evaluated this individualividual.
// Lower fitness = faster construction = better.
type Individual struct {
	NumExcavators       int
	NumDirtTrucks       int
	NumMaterialTrucks   int
	ExcavatorSpawns     []int
	DirtTruckSpawns     []int
	MaterialTruckSpawns []int
	CraneSpawn          int
	Fitness             *float64
}

func (individual *Individual) clone() *Individual {
	c := &Individual{
		NumExcavators:       individual.NumExcavators,
		NumDirtTrucks:       individual.NumDirtTrucks,
		NumMaterialTrucks:   individual.NumMaterialTrucks,
		ExcavatorSpawns:     append([]int(nil), individual.ExcavatorSpawns...),
		DirtTruckSpawns:     append([]int(nil), individual.DirtTruckSpawns...),
		MaterialTruckSpawns: append([]int(nil), individual.MaterialTruckSpawns...),
		CraneSpawn:          individual.CraneSpawn,
	}
	if individual.Fitness != nil {
		f := *individual.Fitness
		c.Fitness = &f
	}
	return c
}

// toSchedule converts the chromosome to the map[time][]agentType format
// expected by the worker's WorkData.
func (individual *Individual) toSchedule() map[string][]string {
	sched := make(map[string][]string)
	add := func(t int, kindividual string) {
		key := strconv.Itoa(t)
		sched[key] = append(sched[key], kindividual)
	}
	for _, t := range individual.ExcavatorSpawns {
		add(t, "excavator")
	}
	for _, t := range individual.DirtTruckSpawns {
		add(t, "dirt_truck")
	}
	for _, t := range individual.MaterialTruckSpawns {
		add(t, "material_truck")
	}
	add(individual.CraneSpawn, "crane")
	return sched
}

func (individual *Individual) summary() string {
	if individual.Fitness != nil {
		return fmt.Sprintf("excavators=%d dirt_trucks=%d material_trucks=%d fitness=%.1fs",
			individual.NumExcavators, individual.NumDirtTrucks, individual.NumMaterialTrucks, *individual.Fitness)
	}
	return fmt.Sprintf("excavators=%d dirt_trucks=%d material_trucks=%d fitness=<unevaluated>",
		individual.NumExcavators, individual.NumDirtTrucks, individual.NumMaterialTrucks)
}

// ---------------------------------------------------------------------------
// GA operators
// ---------------------------------------------------------------------------

func randSpawn(rng *rand.Rand) int {
	return minSpawnTime + rng.Intn(maxSpawnTime-minSpawnTime+1)
}

func clampSpawn(t int) int {
	if t < minSpawnTime {
		return minSpawnTime
	}
	if t > maxSpawnTime {
		return maxSpawnTime
	}
	return t
}

func randomSpawnTimes(rng *rand.Rand, count int) []int {
	times := make([]int, count)
	for i := range times {
		times[i] = randSpawn(rng)
	}
	sort.Ints(times)
	return times
}

func randomIndividual(rng *rand.Rand) *Individual {
	nExc := minExcavators + rng.Intn(maxExcavators-minExcavators+1)
	nDirt := minDirtTrucks + rng.Intn(maxDirtTrucks-minDirtTrucks+1)
	nMat := minMaterialTrucks + rng.Intn(maxMaterialTrucks-minMaterialTrucks+1)
	return &Individual{
		NumExcavators:       nExc,
		NumDirtTrucks:       nDirt,
		NumMaterialTrucks:   nMat,
		ExcavatorSpawns:     randomSpawnTimes(rng, nExc),
		DirtTruckSpawns:     randomSpawnTimes(rng, nDirt),
		MaterialTruckSpawns: randomSpawnTimes(rng, nMat),
		CraneSpawn:          randSpawn(rng),
	}
}

// tournamentSelect picks the fittest of tournamentSize randomly sampled
// individualividuals. All members of population must have Fitness set.
func tournamentSelect(rng *rand.Rand, population []*Individual) *Individual {
	size := tournamentSize
	if size > len(population) {
		size = len(population)
	}
	individualices := rng.Perm(len(population))[:size]
	best := population[individualices[0]]
	for _, i := range individualices[1:] {
		if *population[i].Fitness < *best.Fitness {
			best = population[i]
		}
	}
	return best.clone()
}

// crossTimes builds a sorted spawn-time list of length targetCount by merging
// both parents' lists and evenly sub-sampling. Pads with random times if the
// merged pool is too short.
func crossTimes(rng *rand.Rand, a, b []int, targetCount int) []int {
	pool := make([]int, len(a)+len(b))
	copy(pool, a)
	copy(pool[len(a):], b)
	sort.Ints(pool)

	if len(pool) >= targetCount {
		step := float64(len(pool)) / float64(targetCount)
		result := make([]int, targetCount)
		for i := range result {
			result[i] = pool[int(float64(i)*step)]
		}
		return result // already sorted via pool
	}

	result := append([]int(nil), pool...)
	for len(result) < targetCount {
		result = append(result, randSpawn(rng))
	}
	sort.Ints(result)
	return result
}

// crossover produces two offspring via uniform crossover.
// Applied with probability crossoverProbability; otherwise offspring are
// direct copies of the parents with fitness reset.
func crossover(rng *rand.Rand, a, b *Individual) (*Individual, *Individual) {
	if rng.Float64() > crossoverProbability {
		ca, cb := a.clone(), b.clone()
		ca.Fitness = nil
		cb.Fitness = nil
		return ca, cb
	}

	pick := func(x, y int) int {
		if rng.Intn(2) == 0 {
			return x
		}
		return y
	}

	nExcA := pick(a.NumExcavators, b.NumExcavators)
	nExcB := pick(b.NumExcavators, a.NumExcavators)
	nDirtA := pick(a.NumDirtTrucks, b.NumDirtTrucks)
	nDirtB := pick(b.NumDirtTrucks, a.NumDirtTrucks)
	nMatA := pick(a.NumMaterialTrucks, b.NumMaterialTrucks)
	nMatB := pick(b.NumMaterialTrucks, a.NumMaterialTrucks)

	childA := &Individual{
		NumExcavators:       nExcA,
		NumDirtTrucks:       nDirtA,
		NumMaterialTrucks:   nMatA,
		ExcavatorSpawns:     crossTimes(rng, a.ExcavatorSpawns, b.ExcavatorSpawns, nExcA),
		DirtTruckSpawns:     crossTimes(rng, a.DirtTruckSpawns, b.DirtTruckSpawns, nDirtA),
		MaterialTruckSpawns: crossTimes(rng, a.MaterialTruckSpawns, b.MaterialTruckSpawns, nMatA),
		CraneSpawn:          pick(a.CraneSpawn, b.CraneSpawn),
	}
	childB := &Individual{
		NumExcavators:       nExcB,
		NumDirtTrucks:       nDirtB,
		NumMaterialTrucks:   nMatB,
		ExcavatorSpawns:     crossTimes(rng, a.ExcavatorSpawns, b.ExcavatorSpawns, nExcB),
		DirtTruckSpawns:     crossTimes(rng, a.DirtTruckSpawns, b.DirtTruckSpawns, nDirtB),
		MaterialTruckSpawns: crossTimes(rng, a.MaterialTruckSpawns, b.MaterialTruckSpawns, nMatB),
		CraneSpawn:          pick(b.CraneSpawn, a.CraneSpawn),
	}
	return childA, childB
}

// mutateTimes applies Gaussian perturbation to each spawn time at rate mutationRate.
func mutateTimes(rng *rand.Rand, times []int, sigma float64) []int {
	result := make([]int, len(times))
	for i, t := range times {
		if rng.Float64() < mutationRate {
			t = clampSpawn(t + int(rng.NormFloat64()*sigma))
		}
		result[i] = t
	}
	sort.Ints(result)
	return result
}

// mutateCount increments or decrements an agent count by ±1, adjusting the
// spawn-time list accordingly.
func mutateCount(rng *rand.Rand, current, lo, hi int, times []int) (int, []int) {
	delta := 1
	if rng.Intn(2) == 0 {
		delta = -1
	}
	newCount := current + delta
	if newCount < lo {
		newCount = lo
	}
	if newCount > hi {
		newCount = hi
	}

	newTimes := append([]int(nil), times...)
	switch {
	case newCount > current:
		newTimes = append(newTimes, randSpawn(rng))
	case newCount < current && len(newTimes) > 0:
		i := rng.Intn(len(newTimes))
		newTimes = append(newTimes[:i], newTimes[i+1:]...)
	}
	sort.Ints(newTimes)
	return newCount, newTimes
}

// mutate applies count and spawn-time mutations to individual in place.
// sigma is the current adaptive standard deviation for Gaussian perturbation.
func mutate(rng *rand.Rand, individual *Individual, sigma float64) {
	if rng.Float64() < countMutationRate {
		individual.NumExcavators, individual.ExcavatorSpawns = mutateCount(
			rng, individual.NumExcavators, minExcavators, maxExcavators, individual.ExcavatorSpawns)
	}
	if rng.Float64() < countMutationRate {
		individual.NumDirtTrucks, individual.DirtTruckSpawns = mutateCount(
			rng, individual.NumDirtTrucks, minDirtTrucks, maxDirtTrucks, individual.DirtTruckSpawns)
	}
	if rng.Float64() < countMutationRate {
		individual.NumMaterialTrucks, individual.MaterialTruckSpawns = mutateCount(
			rng, individual.NumMaterialTrucks, minMaterialTrucks, maxMaterialTrucks, individual.MaterialTruckSpawns)
	}
	individual.ExcavatorSpawns = mutateTimes(rng, individual.ExcavatorSpawns, sigma)
	individual.DirtTruckSpawns = mutateTimes(rng, individual.DirtTruckSpawns, sigma)
	individual.MaterialTruckSpawns = mutateTimes(rng, individual.MaterialTruckSpawns, sigma)
	if rng.Float64() < mutationRate {
		individual.CraneSpawn = clampSpawn(individual.CraneSpawn + int(rng.NormFloat64()*sigma))
	}
}

// ---------------------------------------------------------------------------
// Orchestrator — GA state + worker coordination
// ---------------------------------------------------------------------------

type pendingTask struct {
	id                int
	individualividual *Individual
}

type genStats struct {
	Generation          int                 `json:"generation"`
	BestSeconds         float64             `json:"best_seconds"`
	AvgSeconds          float64             `json:"average_seconds"`
	WorstSeconds        float64             `json:"worst_seconds"`
	BestExcavators      int                 `json:"best_excavators"`
	BestDirtTrucks      int                 `json:"best_dirt_trucks"`
	BestMaterialTrucks  int                 `json:"best_material_trucks"`
	BestSchedule        map[string][]string `json:"best_schedule"`
	WorstExcavators     int                 `json:"worst_excavators"`
	WorstDirtTrucks     int                 `json:"worst_dirt_trucks"`
	WorstMaterialTrucks int                 `json:"worst_material_trucks"`
	WorstSchedule       map[string][]string `json:"worst_schedule"`
}

// WorkData matches sim.WorkData in the worker binary.
type WorkData struct {
	ID       string              `json:"id"`
	Schedule map[string][]string `json:"schedule"`
}

// Metrics matches sim.Metrics in the worker binary.
type Metrics struct {
	Time          float32 `json:"time"`
	Phase1Time    float32 `json:"phase1_time"`
	Phase2Time    float32 `json:"phase2_time"`
	TotalVehicles int     `json:"total_vehicles"`
	Timeout       bool    `json:"timeout"`
}

// Orchestrator is the central coordinator. All exported methods are safe to
// call from multiple goroutines; each acquires mu before touching shared state.
type Orchestrator struct {
	mu             sync.Mutex
	rng            *rand.Rand
	populationSize int
	maxGenerations int

	population        []*Individual
	currentGeneration int
	pendingTasks      []pendingTask
	inFlight          map[int]*Individual
	generationResults []*Individual
	nextTaskID        int
	finished          bool
	bestEver          *Individual
	history           []genStats

	// Adaptive sigma state
	currentSigma      float64
	stagnationCounter int
}

func newOrchestrator(populationSize, maxGenerations int) *Orchestrator {
	o := &Orchestrator{
		rng:            rand.New(rand.NewSource(time.Now().UnixNano())),
		populationSize: populationSize,
		maxGenerations: maxGenerations,
		inFlight:       make(map[int]*Individual),
		currentSigma:   mutationSigma,
	}
	log.Printf("Initialising GA — population_size=%d  max_generations=%d  max_sim_time=%ds",
		populationSize, maxGenerations, maxSimTime)

	o.population = make([]*Individual, populationSize)
	for i := range o.population {
		o.population[i] = randomIndividual(o.rng)
	}
	o.enqueue(o.population)
	log.Printf("Generation 0 ready — %d tasks queued", len(o.pendingTasks))
	return o
}

// enqueue resets fitness on each individualividual and appends it to pendingTasks.
// Must be called with mu held (or before the server starts).
func (o *Orchestrator) enqueue(pop []*Individual) {
	for _, individual := range pop {
		individual.Fitness = nil
		o.pendingTasks = append(o.pendingTasks, pendingTask{
			id:                o.nextTaskID,
			individualividual: individual,
		})
		o.nextTaskID++
	}
}

// getNextTask returns a JSON WorkData payload, "wait", or "end".
func (o *Orchestrator) getNextTask() string {
	o.mu.Lock()
	defer o.mu.Unlock()

	if o.finished {
		return "end"
	}
	if len(o.pendingTasks) == 0 {
		return "wait"
	}

	t := o.pendingTasks[0]
	o.pendingTasks = o.pendingTasks[1:]
	o.inFlight[t.id] = t.individualividual

	payload := WorkData{
		ID:       strconv.Itoa(t.id),
		Schedule: t.individualividual.toSchedule(),
		//Schedule: testSchedule,
	}
	data, _ := json.Marshal(payload)
	log.Printf("Dispatched  id=%-4d  gen=%-3d  %s",
		t.id, o.currentGeneration, t.individualividual.summary())
	return string(data)
}

// submitResult records the outcome of one simulation run.
// Triggers evolution when the last result of the generation arrives.
func (o *Orchestrator) submitResult(taskID int, m Metrics) string {
	o.mu.Lock()
	defer o.mu.Unlock()

	individual, ok := o.inFlight[taskID]
	if !ok {
		log.Printf("Handover for unknown task id=%d — ignored", taskID)
		return "unknown_task"
	}
	delete(o.inFlight, taskID)

	var fitness float64
	if m.Timeout {
		fitness = timeoutPenalty
		log.Printf("Timeout  id=%-4d  gen=%-3d  (penalised as %.0f)",
			taskID, o.currentGeneration, timeoutPenalty)
	} else {
		fitness = float64(m.Time)
		log.Printf("Result   id=%-4d  gen=%-3d  time=%.1fs  (%d/%d done)",
			taskID, o.currentGeneration, fitness,
			len(o.generationResults)+1, o.populationSize)
	}
	individual.Fitness = &fitness
	o.generationResults = append(o.generationResults, individual)

	if len(o.generationResults) >= o.populationSize {
		o.evolve()
	}
	return "ok"
}

// evolve runs one full GA evolution step. Must be called with mu held.
func (o *Orchestrator) evolve() {
	evaluated := o.generationResults
	o.generationResults = nil

	// Generation statistics
	best := evaluated[0]
	worst := evaluated[0]
	var sum float64
	for _, individual := range evaluated {
		f := *individual.Fitness
		sum += f
		if f < *best.Fitness {
			best = individual
		}
		if f > *worst.Fitness {
			worst = individual
		}
	}
	avg := sum / float64(len(evaluated))

	log.Printf("Gen %-3d  best=%8.1fs  avg=%8.1fs  worst=%8.1fs  | %s",
		o.currentGeneration, *best.Fitness, avg, *worst.Fitness, best.summary())

	// All-time best + stagnation-based sigma adaptation
	improved := o.bestEver == nil || *best.Fitness < *o.bestEver.Fitness
	if improved {
		o.bestEver = best.clone()
		log.Printf("*** New best in generation %d: %.1fs ***",
			o.currentGeneration, *best.Fitness)
		o.saveBest()
		o.stagnationCounter = 0
		o.currentSigma = math.Max(o.currentSigma*sigmaShrinkFactor, mutationSigmaMin)
		log.Printf("Sigma shrunk → %.0f", o.currentSigma)
	} else {
		o.stagnationCounter++
		if o.stagnationCounter >= stagnationWindow {
			o.currentSigma = math.Min(o.currentSigma*sigmaGrowFactor, mutationSigmaMax)
			log.Printf("Stagnation (%d gens) — sigma grown → %.0f",
				o.stagnationCounter, o.currentSigma)
		}
	}

	o.history = append(o.history, genStats{
		Generation:          o.currentGeneration,
		BestSeconds:         *best.Fitness,
		AvgSeconds:          avg,
		WorstSeconds:        *worst.Fitness,
		BestExcavators:      best.NumExcavators,
		BestDirtTrucks:      best.NumDirtTrucks,
		BestMaterialTrucks:  best.NumMaterialTrucks,
		BestSchedule:        best.toSchedule(),
		WorstExcavators:     worst.NumExcavators,
		WorstDirtTrucks:     worst.NumDirtTrucks,
		WorstMaterialTrucks: worst.NumMaterialTrucks,
		WorstSchedule:       worst.toSchedule(),
	})
	o.saveHistory()

	o.currentGeneration++
	if o.currentGeneration >= o.maxGenerations {
		log.Printf("All %d generations complete.  Best overall: %.1fs",
			o.maxGenerations, *o.bestEver.Fitness)
		o.finished = true
		return
	}

	// Sort ascending (lowest fitness = best first)
	sort.Slice(evaluated, func(i, j int) bool {
		return *evaluated[i].Fitness < *evaluated[j].Fitness
	})

	// Build next generation
	nextGen := make([]*Individual, 0, o.populationSize)

	// Elitism: carry the top eliteCount unchanged
	for i := 0; i < eliteCount && i < len(evaluated); i++ {
		elite := evaluated[i].clone()
		elite.Fitness = nil
		nextGen = append(nextGen, elite)
	}

	// Fill remaining slots: selection → crossover → mutation
	for len(nextGen) < o.populationSize {
		parentA := tournamentSelect(o.rng, evaluated)
		parentB := tournamentSelect(o.rng, evaluated)
		childA, childB := crossover(o.rng, parentA, parentB)
		mutate(o.rng, childA, o.currentSigma)
		mutate(o.rng, childB, o.currentSigma)
		nextGen = append(nextGen, childA)
		if len(nextGen) < o.populationSize {
			nextGen = append(nextGen, childB)
		}
	}

	o.population = nextGen[:o.populationSize]
	o.enqueue(o.population)
	log.Printf("Generation %d queued — %d tasks pending",
		o.currentGeneration, len(o.pendingTasks))
}

func (o *Orchestrator) saveBest() {
	type bestFile struct {
		Generation         int                 `json:"generation"`
		FitnessSeconds     float64             `json:"fitness_seconds"`
		NumExcavators      int                 `json:"num_excavators"`
		NumDirtTrucks      int                 `json:"num_dirt_trucks"`
		MaterialTruckCount int                 `json:"material_truck_count"`
		CraneCount         int                 `json:"crane_count"`
		Schedule           map[string][]string `json:"schedule"`
	}
	data := bestFile{
		Generation:         o.currentGeneration,
		FitnessSeconds:     *o.bestEver.Fitness,
		NumExcavators:      o.bestEver.NumExcavators,
		NumDirtTrucks:      o.bestEver.NumDirtTrucks,
		MaterialTruckCount: o.bestEver.NumMaterialTrucks,
		CraneCount:         craneCount,
		Schedule:           o.bestEver.toSchedule(),
	}
	b, _ := json.MarshalIndent(data, "", "  ")
	path := outputDir + "/best_schedule.json"
	if err := os.WriteFile(path, b, 0644); err != nil {
		log.Printf("saveBest: %v", err)
		return
	}
	log.Printf("Best schedule saved → %s", path)
}

func (o *Orchestrator) saveHistory() {
	b, _ := json.MarshalIndent(o.history, "", "  ")
	path := outputDir + "/generation_history.json"
	if err := os.WriteFile(path, b, 0644); err != nil {
		log.Printf("saveHistory: %v", err)
	}
	if err := saveFitnessChart(o.history, outputDir+"/fitness_curve.jpg"); err != nil {
		log.Printf("saveFitnessChart: %v", err)
	}
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

func (o *Orchestrator) handleStatus(w http.ResponseWriter, _ *http.Request) {
	o.mu.Lock()
	gen := o.currentGeneration
	pending := len(o.pendingTasks)
	inflight := len(o.inFlight)
	finished := o.finished
	best := o.bestEver
	o.mu.Unlock()

	bestLine := "Best so far: none yet"
	if best != nil {
		bestLine = fmt.Sprintf("Best so far: %.1fs", *best.Fitness)
	}
	fmt.Fprintf(w,
		"GA Orchestrator running\nGeneration : %d/%d\nPending    : %d\nIn-flight  : %d\nFinished   : %v\n%s\n",
		gen, o.maxGenerations, pending, inflight, finished, bestLine)
}

func (o *Orchestrator) handleWork(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	fmt.Fprint(w, o.getNextTask())
}

func (o *Orchestrator) handleHandover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	rawID := r.URL.Query().Get("id")
	taskID, err := strconv.Atoi(rawID)
	if err != nil {
		log.Printf("/handover bad id=%q: %v", rawID, err)
		http.Error(w, "bad_request", http.StatusBadRequest)
		return
	}
	var m Metrics
	if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
		log.Printf("/handover bad body id=%d: %v", taskID, err)
		http.Error(w, "bad_request", http.StatusBadRequest)
		return
	}
	fmt.Fprint(w, o.submitResult(taskID, m))
}

func (o *Orchestrator) handleAnswers(w http.ResponseWriter, _ *http.Request) {
	o.mu.Lock()
	gen := o.currentGeneration
	evaluated := len(o.generationResults)
	best := o.bestEver
	history := append([]genStats(nil), o.history...)
	o.mu.Unlock()

	var sb strings.Builder
	fmt.Fprintf(&sb, "Generation  : %d/%d\n", gen, o.maxGenerations)
	fmt.Fprintf(&sb, "Evaluated   : %d/%d\n", evaluated, o.populationSize)
	if best != nil {
		fmt.Fprintf(&sb, "Best ever   : %.1fs\n", *best.Fitness)
	}
	sb.WriteString("\nLast 5 generations:\n")
	start := len(history) - 5
	if start < 0 {
		start = 0
	}
	for _, e := range history[start:] {
		fmt.Fprintf(&sb, "  gen %3d  best=%8.1fs  avg=%8.1fs  excavators=%d  dirt_trucks=%d  material_trucks=%d\n",
			e.Generation, e.BestSeconds, e.AvgSeconds, e.BestExcavators, e.BestDirtTrucks, e.BestMaterialTrucks)
	}
	fmt.Fprint(w, sb.String())
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	addr := flag.String("addr", defaultAddr, "listen address")
	population := flag.Int("population", 20, "GA population size")
	generations := flag.Int("generations", 50, "number of GA generations")
	flag.Parse()

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		log.Fatalf("cannot create output dir %q: %v", outputDir, err)
	}

	// Tee log output to both stderr and a file.
	logFile, err := os.OpenFile(outputDir+"/orchestrator.log",
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Fatalf("cannot open log file: %v", err)
	}
	defer logFile.Close()
	log.SetOutput(io.MultiWriter(os.Stderr, logFile))
	log.SetFlags(log.LstdFlags)

	o := newOrchestrator(*population, *generations)

	mux := http.NewServeMux()
	mux.HandleFunc("/", o.handleStatus)
	mux.HandleFunc("/work", o.handleWork)
	mux.HandleFunc("/handover", o.handleHandover)
	mux.HandleFunc("/answers", o.handleAnswers)

	srv := &http.Server{Addr: *addr, Handler: mux}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		log.Println("Shutting down…")
		os.Exit(0)
	}()

	log.Printf("Server starting on %s  (population=%d  generations=%d  max_sim=%ds)",
		*addr, *population, *generations, maxSimTime)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server: %v", err)
	}
}
