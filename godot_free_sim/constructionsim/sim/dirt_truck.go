package sim

import "log"

type DirtTruckState int

const (
	DirtSpawned DirtTruckState = iota
	DirtSearching
	DirtMovingToExcavator
	DirtFollowing
	DirtReturning
	DirtUnloading
	DirtLeaving
	DirtDespawned
)

type DirtTruck struct {
	BaseVehicle
	State         DirtTruckState
	Cargo         int
	AssignedExcav *Excavator
	UnloadTimer   float32
	SearchTimer   float32
	WanderTarget  Point
	IsWandering   bool
	WanderTimer   float32
	followTarget  Point // last A* goal used in handleFollowing
}

func NewDirtTruck(id int, spawnPos Vec2) *DirtTruck {
	return &DirtTruck{
		BaseVehicle: BaseVehicle{
			ID:                 id,
			Pos:                spawnPos,
			Radius:             1.7,
			BaseSpeed:          5.0,
			SpawnImmunityTicks: 20,
		},
		State: DirtSpawned,
	}
}

func (t *DirtTruck) GetType() VehicleType { return TypeDirtTruck }

func (t *DirtTruck) SetLeaving() {
	if t.State != DirtDespawned {
		if t.AssignedExcav != nil {
			t.AssignedExcav.UnassignTruck(t)
			t.AssignedExcav = nil
		}
		t.State = DirtLeaving
	}
}

func (t *DirtTruck) IsDespawned() bool { return t.State == DirtDespawned }

func (t *DirtTruck) Update(s *Simulation, dt float32) {
	if t.SpawnImmunityTicks > 0 {
		t.SpawnImmunityTicks--
	}
	UpdateOccupancy(s.Grid, &t.BaseVehicle)

	switch t.State {
	case DirtSpawned:
		if s.Phase.Phase1Complete {
			t.State = DirtLeaving
		} else {
			t.State = DirtSearching
			t.searchExcavator(s)
		}
	case DirtSearching:
		t.handleSearching(s, dt)
	case DirtMovingToExcavator:
		t.handleMovingToExcavator(s, dt)
	case DirtFollowing:
		t.handleFollowing(s, dt)
	case DirtReturning:
		t.handleLeavingForUnloading(s, dt)
	case DirtUnloading:
		t.handleUnloading(s, dt)
	case DirtLeaving:
		t.handleLeaving(s, dt)
	}
}

func (t *DirtTruck) searchExcavator(s *Simulation) {
	// Priority 1: no trucks AND waiting for truck
	// Priority 2: no trucks
	// Priority 3: has one truck
	var best *Excavator
	priority := -1
	for _, v := range s.Vehicles {
		e, ok := v.(*Excavator)
		if !ok || e.IsDespawned() {
			continue
		}
		if s.Phase.Phase1Complete {
			continue
		}
		tc := e.TruckCount()
		p := -1
		if tc == 0 && e.IsWaitingForTruck() {
			p = 0
		} else if tc == 0 {
			p = 1
		}
		if p >= 0 && (priority < 0 || p < priority) {
			best = e
			priority = p
		}
	}

	if best != nil && best.AssignTruck(t) {
		t.AssignedExcav = best
		t.PathfindTo(s.Grid, best.CurrentCell(s.Grid))
		t.State = DirtMovingToExcavator
		log.Printf("[DT#%d] assigned to EX#%d (priority=%d) path_len=%d", t.ID, best.ID, priority, len(t.Path))
		return
	}
	log.Printf("[DT#%d] no excavator found (searching)", t.ID)

	// Not found — wander or wait
	t.State = DirtSearching
	t.SearchTimer = 0
	if dist2(t.Pos, s.SpawnPos) < 3.0 {
		target := s.WanderTarget(t.ID, 5, 15)
		t.WanderTarget = target
		t.IsWandering = true
		t.PathfindTo(s.Grid, target)
	}
}

func (t *DirtTruck) handleSearching(s *Simulation, dt float32) {
	if t.IsWandering {
		t.FollowPath(s.Grid, s.Vehicles, dt)
		if t.PathDone() {
			t.IsWandering = false
		}
		return
	}
	t.SearchTimer += dt
	if t.SearchTimer >= 10.0 {
		t.SearchTimer = 0
		t.searchExcavator(s)
	}
}

func (t *DirtTruck) handleMovingToExcavator(s *Simulation, dt float32) {
	if t.AssignedExcav == nil || t.AssignedExcav.IsDespawned() {
		t.AssignedExcav = nil
		t.State = DirtSearching
		return
	}
	// Check inactivity
	if s.SimTime-t.AssignedExcav.LastActivityTime > 60.0 {
		log.Printf("[DT#%d] EX#%d inactive >60s, unassigning", t.ID, t.AssignedExcav.ID)
		t.AssignedExcav.UnassignTruck(t)
		t.AssignedExcav = nil
		t.State = DirtSearching
		return
	}

	// If path is exhausted but we haven't arrived, excavator moved — re-pathfind.
	if t.PathDone() {
		log.Printf("[DT#%d] path done but not within 2m of EX#%d, re-pathing", t.ID, t.AssignedExcav.ID)
		t.PathfindTo(s.Grid, t.AssignedExcav.CurrentCell(s.Grid))
	}
	t.CheckRepath(s.Grid, t.AssignedExcav.CurrentCell(s.Grid), dt)
	t.FollowPath(s.Grid, s.Vehicles, dt)

	if dist2(t.Pos, t.AssignedExcav.Pos) <= 2.0 {
		log.Printf("[DT#%d] arrived at EX#%d → FOLLOWING", t.ID, t.AssignedExcav.ID)
		t.State = DirtFollowing
	}
}

func (t *DirtTruck) handleFollowing(s *Simulation, dt float32) {
	if t.AssignedExcav == nil || t.AssignedExcav.IsDespawned() {
		t.AssignedExcav = nil
		t.State = DirtSearching
		return
	}
	// Check inactivity
	if s.SimTime-t.AssignedExcav.LastActivityTime > 60.0 {
		log.Printf("[DT#%d] EX#%d inactive >60s while following, unassigning", t.ID, t.AssignedExcav.ID)
		t.AssignedExcav.UnassignTruck(t)
		t.AssignedExcav = nil
		t.State = DirtSearching
		return
	}

	// Maintain standoff distance.
	if dist2(t.Pos, t.AssignedExcav.Pos) <= t.Radius {
		return
	}

	// Route via the excavator's trail so the path respects walls.
	// When the trail is empty fall back to the excavator's current cell.
	goal := t.AssignedExcav.CurrentCell(s.Grid)
	if trail := t.AssignedExcav.Trail; len(trail) > 0 {
		goal = trail[len(trail)-1]
	}

	if goal != t.followTarget || t.PathDone() {
		t.followTarget = goal
		t.PathfindTo(s.Grid, goal)
	}
	t.CheckRepath(s.Grid, goal, dt)
	t.FollowPath(s.Grid, s.Vehicles, dt)
}

func (t *DirtTruck) handleLeavingForUnloading(s *Simulation, dt float32) {
	t.BaseSpeed = 3.0 // The trailer is full, which is why the truck has to drive slower
	t.CheckRepath(s.Grid, s.SpawnCell(), dt)
	t.FollowPath(s.Grid, s.Vehicles, dt)
	if dist2(t.Pos, s.SpawnPos) < 3.0 {
		log.Printf("[DT#%d] at spawn → UNLOADING (cargo=%d)", t.ID, t.Cargo)
		t.State = DirtUnloading
		t.UnloadTimer = 0
	}
}

func (t *DirtTruck) handleUnloading(s *Simulation, dt float32) {
	t.UnloadTimer += dt
	if t.UnloadTimer >= 1800.0 {
		t.BaseSpeed = 5.0 // trailer is empty, back to original speed
		log.Printf("[DT#%d] unloaded → SEARCHING", t.ID)
		t.Cargo = 0
		t.State = DirtSearching
		t.SearchTimer = 0
		t.searchExcavator(s)
	}
}

func (t *DirtTruck) handleLeaving(s *Simulation, dt float32) {
	t.RetryPathfind(s.Grid, s.SpawnCell(), dt)
	t.FollowPath(s.Grid, s.Vehicles, dt)
	if dist2(t.Pos, s.SpawnPos) < 3.0 {
		ClearOccupancy(s.Grid, &t.BaseVehicle)
		t.State = DirtDespawned
	}
}
