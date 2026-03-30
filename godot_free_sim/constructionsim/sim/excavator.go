package sim

import "log"

type ExcavatorState int

const (
	ExcavSpawned ExcavatorState = iota
	ExcavMovingToCell
	ExcavWaitingForTruck
	ExcavExcavating
	ExcavLeaving
	ExcavDespawned
)

type Excavator struct {
	BaseVehicle
	State            ExcavatorState
	TargetCell       Point
	ExcavTimer       float32
	LastActivityTime float32
	AssignedTrucks   []*DirtTruck
	ActiveTruck      *DirtTruck
	WanderTarget     Vec2
	HasWandered      bool
	InactivityTimer  float32
	Trail            []Point // recent cells visited while moving, oldest first
	trailCell        Point   // last cell appended, to avoid duplicates
}

func NewExcavator(id int, spawnPos Vec2) *Excavator {
	return &Excavator{
		BaseVehicle: BaseVehicle{
			ID:                 id,
			Pos:                spawnPos,
			Radius:             1.5,
			BaseSpeed:          2.5,
			SpawnImmunityTicks: 20,
		},
		State:      ExcavSpawned,
		TargetCell: Point{-1, -1},
		trailCell:  Point{-1, -1},
	}
}

func (e *Excavator) GetType() VehicleType { return TypeExcavator }

func (e *Excavator) SetLeaving() {
	if e.State != ExcavDespawned {
		e.State = ExcavLeaving
	}
}

func (e *Excavator) IsDespawned() bool { return e.State == ExcavDespawned }

func (e *Excavator) Update(s *Simulation, dt float32) {
	if e.SpawnImmunityTicks > 0 {
		e.SpawnImmunityTicks--
	}
	UpdateOccupancy(s.Grid, &e.BaseVehicle)

	switch e.State {
	case ExcavSpawned:
		e.handleSpawned(s, dt)
	case ExcavMovingToCell:
		e.handleMovingToCell(s, dt)
	case ExcavWaitingForTruck:
		e.handleWaitingForTruck(s, dt)
	case ExcavExcavating:
		e.handleExcavating(s, dt)
	case ExcavLeaving:
		e.handleLeaving(s, dt)
	}
}

func (e *Excavator) handleSpawned(s *Simulation, dt float32) {
	e.LastActivityTime = s.SimTime // wandering counts as active
	spawn := s.SpawnPos
	if dist2(e.Pos, spawn) < 3.0 && !e.HasWandered {
		target := s.RandomWalkable(5, 15)
		e.WanderTarget = CellCenter(target)
		e.PathfindTo(s.Grid, target)
		e.HasWandered = true
		return
	}
	if e.HasWandered && !e.PathDone() {
		e.FollowPath(s.Grid, dt)
		return
	}
	e.findAndReserveCell(s)
}

func (e *Excavator) findAndReserveCell(s *Simulation) {
	g := s.Grid
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			c := &g.Cells[y][x]
			if c.Excavate && !c.ExcavDone && c.Reserved == -1 {
				c.Reserved = e.ID
				e.TargetCell = Point{x, y}
				e.PathfindTo(g, Point{x, y})
				e.State = ExcavMovingToCell
				log.Printf("[EX#%d] reserved cell (%d,%d) path_len=%d", e.ID, x, y, len(e.Path))
				return
			}
		}
	}
	// No cell found, leave
	log.Printf("[EX#%d] no cells left, leaving", e.ID)
	spawnCell := s.SpawnCell()
	e.PathfindTo(s.Grid, spawnCell)
	e.State = ExcavLeaving
}

func (e *Excavator) appendTrail(p Point) {
	if p == e.trailCell {
		return
	}
	e.trailCell = p
	e.Trail = append(e.Trail, p)
	if len(e.Trail) > 50 {
		e.Trail = e.Trail[1:]
	}
}

func (e *Excavator) handleMovingToCell(s *Simulation, dt float32) {
	e.LastActivityTime = s.SimTime // moving to cell counts as active
	e.CheckRepath(s.Grid, e.TargetCell, dt)
	e.FollowPath(s.Grid, dt)
	e.appendTrail(e.CurrentCell(s.Grid))
	// Safety net: if path was exhausted (e.g. detour ended short) re-pathfind.
	e.RetryPathfind(s.Grid, e.TargetCell, dt)

	cellCenter := CellCenter(e.TargetCell)
	if dist2(e.Pos, cellCenter) <= 1.5 {
		e.State = ExcavWaitingForTruck
		e.InactivityTimer = 0
		e.LastActivityTime = s.SimTime
		log.Printf("[EX#%d] arrived at cell (%d,%d) pos=(%.1f,%.1f) assigned_trucks=%d",
			e.ID, e.TargetCell.X, e.TargetCell.Y, e.Pos.X, e.Pos.Y, len(e.AssignedTrucks))
	}
}

func (e *Excavator) handleWaitingForTruck(s *Simulation, dt float32) {
	e.LastActivityTime = s.SimTime // waiting at a cell counts as active
	e.InactivityTimer += dt
	// Check if a truck is within 2m
	for _, t := range e.AssignedTrucks {
		if t.State == DirtFollowing || t.State == DirtMovingToExcavator {
			if dist2(e.Pos, t.Pos) <= 2.0 {
				e.ActiveTruck = t
				t.State = DirtFollowing
				e.State = ExcavExcavating
				e.ExcavTimer = 0
				e.LastActivityTime = s.SimTime
				log.Printf("[EX#%d] START excavating (%d,%d) with truck#%d",
					e.ID, e.TargetCell.X, e.TargetCell.Y, t.ID)
				// Set synthetic occupancy on target cell
				c := s.Grid.At(e.TargetCell.X, e.TargetCell.Y)
				c.Occupancy[SyntheticExcavID] = 1.0
				return
			}
		}
	}
	// No truck arrived after 90s — abandon cell and find another
	if e.InactivityTimer > 90.0 {
		log.Printf("[EX#%d] no truck arrived after 90s at (%d,%d), retrying",
			e.ID, e.TargetCell.X, e.TargetCell.Y)
		cell := s.Grid.At(e.TargetCell.X, e.TargetCell.Y)
		cell.Reserved = -1
		delete(cell.Occupancy, SyntheticExcavID)
		e.InactivityTimer = 0
		e.findAndReserveCell(s)
	}
}

func (e *Excavator) handleExcavating(s *Simulation, dt float32) {
	e.LastActivityTime = s.SimTime // actively digging counts as active
	e.ExcavTimer += dt
	if e.ExcavTimer >= 120.0 {
		// Complete excavation
		cell := s.Grid.At(e.TargetCell.X, e.TargetCell.Y)
		cell.ExcavDone = true
		cell.Height -= 1
		cell.Reserved = -1
		delete(cell.Occupancy, SyntheticExcavID)
		s.Grid.UpdateEdgesAround(e.TargetCell.X, e.TargetCell.Y)
		s.Phase.RecordExcavation(s.SimTime)
		log.Printf("[EX#%d] DONE cell (%d,%d) total_excav=%d/%d",
			e.ID, e.TargetCell.X, e.TargetCell.Y, s.Phase.ExcavDone, s.Phase.TotalExcavation)

		// Fill active truck cargo
		if e.ActiveTruck != nil && e.ActiveTruck.State == DirtFollowing {
			e.ActiveTruck.Cargo++
			if e.ActiveTruck.Cargo >= 20 {
				departed := e.ActiveTruck
				departed.State = DirtReturning
				departed.PathfindTo(s.Grid, s.SpawnCell())
				departed.AssignedExcav = nil
				e.UnassignTruck(departed)
				log.Printf("[DT#%d] cargo full → RETURNING (unassigned from EX#%d)", departed.ID, e.ID)
				e.ActiveTruck = nil
				// Next assigned truck becomes active
				for _, t := range e.AssignedTrucks {
					if t != nil && t.State == DirtFollowing {
						e.ActiveTruck = t
						log.Printf("[EX#%d] DT#%d is now active truck", e.ID, t.ID)
						break
					}
				}
			}
		}

		e.LastActivityTime = s.SimTime
		if s.Phase.CheckPhase1(s.SimTime) {
			s.SignalPhase1Complete()
			return
		}

		e.findAndReserveCell(s)
	}
}

func (e *Excavator) handleLeaving(s *Simulation, dt float32) {
	e.RetryPathfind(s.Grid, s.SpawnCell(), dt)
	e.FollowPath(s.Grid, dt)
	if dist2(e.Pos, s.SpawnPos) < 3.0 {
		ClearOccupancy(s.Grid, &e.BaseVehicle)
		e.State = ExcavDespawned
	}
}

func (e *Excavator) AssignTruck(t *DirtTruck) bool {
	for _, at := range e.AssignedTrucks {
		if at == t {
			return true
		}
	}
	if len(e.AssignedTrucks) < 1 {
		e.AssignedTrucks = append(e.AssignedTrucks, t)
		return true
	}
	return false
}

func (e *Excavator) UnassignTruck(t *DirtTruck) {
	for i, at := range e.AssignedTrucks {
		if at == t {
			e.AssignedTrucks = append(e.AssignedTrucks[:i], e.AssignedTrucks[i+1:]...)
			if e.ActiveTruck == t {
				e.ActiveTruck = nil
			}
			return
		}
	}
}

func (e *Excavator) TruckCount() int {
	return len(e.AssignedTrucks)
}

func (e *Excavator) IsWaitingForTruck() bool {
	return e.State == ExcavWaitingForTruck
}
