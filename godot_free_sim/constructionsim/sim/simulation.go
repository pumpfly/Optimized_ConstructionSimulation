package sim

import (
	"hash/fnv"
	"log"
	"math"
	"math/rand"
	"strconv"
)

const SimStep = 0.05

type WorkData struct {
	ID       string              `json:"id"`
	Schedule map[string][]string `json:"schedule"`
}

type Metrics struct {
	Time          float32 `json:"time"`
	Phase1Time    float32 `json:"phase1_time"`
	Phase2Time    float32 `json:"phase2_time"`
	TotalVehicles int     `json:"total_vehicles"`
	Timeout       bool    `json:"timeout"`
}

type Simulation struct {
	Grid          *Grid
	Phase         *PhaseManager
	Vehicles      []Updatable
	SpawnPos      Vec2
	SimTime       float32
	LastDT        float32
	nextID        int
	rng           *rand.Rand
	pendingSpawns []pendingSpawn
	done          bool
	metrics       Metrics
	lastLogTime   float32
}

type pendingSpawn struct {
	time    float32
	typeStr string
}

func NewSimulation(g *Grid, work WorkData) *Simulation {
	g.Reset()
	h := fnv.New64a()
	h.Write([]byte(work.ID))
	seed := int64(h.Sum64())

	s := &Simulation{
		Grid:     g,
		Phase:    NewPhaseManager(g),
		SpawnPos: Vec2{float32(g.Spawn.X) + 0.5, float32(g.Spawn.Y) + 0.5},
		rng:      rand.New(rand.NewSource(seed)),
		nextID:   1,
	}

	// Parse schedule — collect in order: sort by time, then by array index
	type entry struct {
		time    float32
		typeStr string
		order   int
	}
	var entries []entry
	order := 0
	for tsStr, types := range work.Schedule {
		f, err := strconv.ParseFloat(tsStr, 64)
		if err != nil {
			continue
		}
		t := float32(f)
		for _, vt := range types {
			entries = append(entries, entry{t, vt, order})
			order++
		}
	}
	// Sort by time, then by original order index
	for i := 1; i < len(entries); i++ {
		for j := i; j > 0; j-- {
			a, b := entries[j-1], entries[j]
			if a.time > b.time || (a.time == b.time && a.order > b.order) {
				entries[j-1], entries[j] = entries[j], entries[j-1]
			} else {
				break
			}
		}
	}
	for _, e := range entries {
		s.pendingSpawns = append(s.pendingSpawns, pendingSpawn{e.time, e.typeStr})
	}

	// Check if phase1 is immediately complete
	if s.Phase.TotalExcavation == 0 {
		s.Phase.Phase1Complete = true
		s.Phase.Phase1CompleteAt = 0
	}

	return s
}

func (s *Simulation) SpawnCell() Point {
	return Point{int(s.SpawnPos.X), int(s.SpawnPos.Y)}
}

func (s *Simulation) allocID() int {
	id := s.nextID
	s.nextID++
	return id
}

func (s *Simulation) spawnVehicle(typeStr string) {
	id := s.allocID()
	var v Updatable
	switch typeStr {
	case "excavator":
		v = NewExcavator(id, s.SpawnPos)
	case "dirt_truck":
		v = NewDirtTruck(id, s.SpawnPos)
	case "crane":
		v = NewCrane(id, s.SpawnPos)
	case "material_truck":
		v = NewMaterialTruck(id, s.SpawnPos)
	default:
		return
	}
	log.Printf("[t=%.1f] SPAWN id=%d type=%s pos=(%.1f,%.1f)", s.SimTime, id, typeStr, s.SpawnPos.X, s.SpawnPos.Y)
	s.Vehicles = append(s.Vehicles, v)
}

func (s *Simulation) Tick(dt float32) {
	if s.done {
		return
	}
	s.LastDT = dt
	s.SimTime += dt

	// Timeout check
	if s.SimTime > 43200.0 {
		s.finalize(true)
		return
	}

	// Spawn pending vehicles
	for len(s.pendingSpawns) > 0 && s.pendingSpawns[0].time <= s.SimTime {
		s.spawnVehicle(s.pendingSpawns[0].typeStr)
		s.pendingSpawns = s.pendingSpawns[1:]
	}

	// Update vehicles in order
	for _, v := range s.Vehicles {
		if !v.IsDespawned() {
			v.Update(s, dt)
		}
	}

	// Periodic state summary every 60s of sim-time.
	if s.SimTime-s.lastLogTime >= 60.0 {
		s.lastLogTime = s.SimTime
		s.logStatus()
	}

	// Proactive phase 2 check covers the TotalConstruct==0 case and any
	// scenario where CheckPhase2 wasn't triggered through normal excavation flow.
	if s.Phase.Phase1Complete && !s.Phase.Phase2Complete {
		if s.Phase.CheckPhase2(s.SimTime) {
			s.SignalPhase2Complete()
		}
	}

	// Check if all despawned and all construction is complete
	if len(s.pendingSpawns) == 0 && s.Phase.Phase2Complete {
		allDone := true
		for _, v := range s.Vehicles {
			if !v.IsDespawned() {
				allDone = false
				break
			}
		}
		if allDone {
			s.finalize(false)
		}
	}
}

func (s *Simulation) finalize(timeout bool) {
	if s.done {
		return
	}
	s.done = true
	if timeout {
		log.Printf("[t=%.1f] TIMEOUT — logging vehicle states:", s.SimTime)
		for _, v := range s.Vehicles {
			if !v.IsDespawned() {
				log.Printf("  id=%d type=%d pos=(%.1f,%.1f)", v.GetID(), v.GetType(), v.GetPos().X, v.GetPos().Y)
			}
		}
	} else {
		log.Printf("[t=%.1f] DONE", s.SimTime)
	}

	p1t := s.Phase.Phase1CompleteAt
	p2t := float32(0)
	if s.Phase.Phase2Complete {
		p2t = s.Phase.Phase2CompleteAt - s.Phase.Phase1CompleteAt
	}

	total := s.SimTime
	if timeout {
		total = s.SimTime * 1.5
		if !s.Phase.Phase1Complete {
			p1t = s.SimTime
		}
	}

	s.metrics = Metrics{
		Time:          total,
		Phase1Time:    p1t,
		Phase2Time:    p2t,
		TotalVehicles: len(s.Vehicles),
		Timeout:       timeout,
	}
}

func (s *Simulation) logStatus() {
	active := 0
	for _, v := range s.Vehicles {
		if !v.IsDespawned() {
			active++
		}
	}
	log.Printf("[t=%.1f] STATUS excav=%d/%d constr=%d/%d vehicles=%d pending_spawns=%d",
		s.SimTime,
		s.Phase.ExcavDone, s.Phase.TotalExcavation,
		s.Phase.ConstrDone, s.Phase.TotalConstruct,
		active, len(s.pendingSpawns))
}

func (s *Simulation) IsDone() bool {
	return s.done
}

func (s *Simulation) Metrics() Metrics {
	return s.metrics
}

func (s *Simulation) SignalPhase1Complete() {
	log.Printf("[t=%.1f] PHASE 1 COMPLETE", s.SimTime)
	for _, v := range s.Vehicles {
		switch v.(type) {
		case *Excavator, *DirtTruck:
			v.SetLeaving()
		}
	}
	// Activate cranes and material trucks waiting for phase2
	for _, v := range s.Vehicles {
		switch vt := v.(type) {
		case *Crane:
			if vt.State == CraneWaitingForPhase2 {
				vt.State = CranePositioning
				vt.findPositioningTarget(s)
			}
		case *MaterialTruck:
			if vt.State == MatWaitingForPhase2 {
				vt.State = MatSearching
				vt.searchCrane(s)
			}
		}
	}
	// Check if phase2 is immediately complete
	if s.Phase.TotalConstruct == 0 {
		s.Phase.CheckPhase2(s.SimTime)
		s.SignalPhase2Complete()
	}
}

func (s *Simulation) SignalPhase2Complete() {
	log.Printf("[t=%.1f] PHASE 2 COMPLETE", s.SimTime)
	for _, v := range s.Vehicles {
		v.SetLeaving()
	}
}

func (s *Simulation) RandomWalkable(minDist, maxDist float32) Point {
	spawnX := int(s.SpawnPos.X)
	spawnY := int(s.SpawnPos.Y)
	spawnH := s.Grid.At(spawnX, spawnY).Height

	for i := 0; i < 50; i++ {
		angle := s.rng.Float64() * 2 * math.Pi
		dist := minDist + s.rng.Float32()*(maxDist-minDist)
		tx := spawnX + int(float64(dist)*math.Cos(angle))
		ty := spawnY + int(float64(dist)*math.Sin(angle))
		if !s.Grid.InBounds(tx, ty) {
			continue
		}
		if abs32(s.Grid.At(tx, ty).Height-spawnH) > 3 {
			continue
		}
		return Point{tx, ty}
	}
	// Fallback: 5m in +x direction
	fx := spawnX + 5
	if fx >= s.Grid.Width {
		fx = s.Grid.Width - 1
	}
	return Point{fx, spawnY}
}
