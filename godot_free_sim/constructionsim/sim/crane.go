package sim

import (
	"log"
	"math"
)

type CraneState int

const craneWorkRadius = 30.0

const (
	CraneSpawned CraneState = iota
	CraneWaitingForPhase2
	CranePositioning
	CraneWorking
	CraneLeaving
	CraneDespawned
)

type Crane struct {
	BaseVehicle
	State            CraneState
	PlaceTimer       float32
	PlaceTimerActive bool
	CurrentTarget    Point
	AssignedTrucks   []*MaterialTruck
	WanderTarget     Point
	WanderDone       bool
	InRangeTimer     float32 // seconds since first target entered work radius; -1 = none in range yet
	Trail            []Point // recent cells visited while positioning, oldest first
	trailCell        Point   // last cell appended, to avoid duplicates
}

func NewCrane(id int, spawnPos Vec2) *Crane {
	return &Crane{
		BaseVehicle: BaseVehicle{
			ID:                 id,
			Pos:                spawnPos,
			Radius:             5,
			BaseSpeed:          2.4,
			SpawnImmunityTicks: 20,
		},
		State:        CraneSpawned,
		InRangeTimer: -1,
		trailCell:    Point{-1, -1},
	}
}

func (c *Crane) GetType() VehicleType { return TypeCrane }

func (c *Crane) SetLeaving() {
	if c.State != CraneDespawned {
		c.State = CraneLeaving
		// Discard any stale path (e.g. leftover positioning path that was
		// interrupted by allConstructInRange) so handleLeaving paths to
		// spawn immediately instead of finishing the old route first.
		c.Path = nil
		c.PathIdx = 0
	}
}

func (c *Crane) IsDespawned() bool { return c.State == CraneDespawned }

func (c *Crane) Update(s *Simulation, dt float32) {
	if c.SpawnImmunityTicks > 0 {
		c.SpawnImmunityTicks--
	}
	UpdateOccupancy(s.Grid, &c.BaseVehicle)

	switch c.State {
	case CraneSpawned:
		c.handleSpawned(s)
	case CraneWaitingForPhase2:
		c.handleWaiting(s, dt)
	case CranePositioning:
		c.handlePositioning(s, dt)
	case CraneWorking:
		c.handleWorking(s, dt)
	case CraneLeaving:
		c.handleLeaving(s, dt)
	}
}

func (c *Crane) handleSpawned(s *Simulation) {
	if !s.Phase.Phase1Complete {
		target := s.RandomWalkable(5, 15)
		c.WanderTarget = target
		c.WanderDone = false
		c.PathfindTo(s.Grid, target)
		c.State = CraneWaitingForPhase2
		return
	}
	c.State = CranePositioning
	c.findPositioningTarget(s)
}

func (c *Crane) handleWaiting(s *Simulation, dt float32) {
	if !c.WanderDone {
		c.FollowPath(s.Grid, s.Vehicles, dt)
		if c.PathDone() {
			c.WanderDone = true
		}
	}
	if s.Phase.Phase1Complete {
		c.State = CranePositioning
		c.findPositioningTarget(s)
	}
}

func (c *Crane) appendTrail(p Point) {
	if p == c.trailCell {
		return
	}
	c.trailCell = p
	c.Trail = append(c.Trail, p)
	if len(c.Trail) > 50 {
		c.Trail = c.Trail[1:]
	}
}

func (c *Crane) handlePositioning(s *Simulation, dt float32) {
	c.CheckRepath(s.Grid, c.WanderTarget, dt)
	c.FollowPath(s.Grid, s.Vehicles, dt)
	c.appendTrail(c.CurrentCell(s.Grid))

	// Always commit to Working when the path is fully consumed.
	if c.PathDone() {
		log.Printf("[CR#%d] reached positioning target → WORKING pos=(%.1f,%.1f)", c.ID, c.Pos.X, c.Pos.Y)
		c.InRangeTimer = -1
		c.State = CraneWorking
		c.PlaceTimerActive = false
		return
	}

	// While still moving: start a 5s countdown the moment the first
	// unfinished cell enters the work radius. If the crane drifts back out
	// of range before the countdown finishes, reset it. This lets the crane
	// keep moving to pick up additional targets rather than stopping the
	// instant the first one appears.
	if c.isPipePlacementCellInRange(s) {
		if c.InRangeTimer < 0 {
			c.InRangeTimer = 0
		}
		c.InRangeTimer += dt
		if c.InRangeTimer >= 5.0 {
			log.Printf("[CR#%d] target in range for 5s → WORKING pos=(%.1f,%.1f)", c.ID, c.Pos.X, c.Pos.Y)
			c.InRangeTimer = -1
			c.State = CraneWorking
			c.PlaceTimerActive = false
		}
	} else {
		c.InRangeTimer = -1
	}
}

// isPipePlacementCellInRange returns true if at least one unfinished construction
// cell is within the crane's work radius.
func (c *Crane) isPipePlacementCellInRange(s *Simulation) bool {
	g := s.Grid
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			cell := &g.Cells[y][x]
			if cell.PipePlacementCell && !cell.ConstrDone {
				d := dist2(c.Pos, Vec2{float32(x) + 0.5, float32(y) + 0.5})
				if d <= craneWorkRadius {
					return true
				}
			}
		}
	}
	return false
}

func (c *Crane) findPositioningTarget(s *Simulation) {
	// Find nearest unfinished PipePlacementCell
	g := s.Grid

	bestDist := float32(math.MaxFloat32)
	best := Point{-1, -1}
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			cell := &g.Cells[y][x]
			if cell.PipePlacementCell && !cell.ConstrDone {
				d := dist2(c.Pos, Vec2{float32(x) + 0.5, float32(y) + 0.5})
				if d < bestDist {
					bestDist = d
					best = Point{x, y}
				}
			}
		}
	}

	c.InRangeTimer = -1
	if best.X >= 0 {
		c.WanderTarget = best
		c.PathfindTo(s.Grid, best)
		log.Printf("[CR#%d] positioning toward (%d,%d) dist=%.1f path_len=%d",
			c.ID, best.X, best.Y, bestDist, len(c.Path))
	} else {
		log.Printf("[CR#%d] no construction cells left to position toward", c.ID)
	}
}

func (c *Crane) handleWorking(s *Simulation, dt float32) {
	if c.PlaceTimerActive {
		c.PlaceTimer += dt
		if c.PlaceTimer >= 300.0 {
			c.PlaceTimerActive = false
			// Mark cell done
			g := s.Grid
			cell := &g.Cells[c.CurrentTarget.Y][c.CurrentTarget.X]
			cell.ConstrDone = true
			s.Phase.RecordConstruction(s.SimTime)
			if s.Phase.CheckPhase2(s.SimTime) {
				s.SignalPhase2Complete()
				return
			}
		}
		return
	}

	// Find next unfinished construction cell within craneWorkRadius
	g := s.Grid
	bestDist := float32(math.MaxFloat32)
	best := Point{-1, -1}
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			cell := &g.Cells[y][x]
			if cell.PipePlacementCell && !cell.ConstrDone {
				d := dist2(c.Pos, Vec2{float32(x) + 0.5, float32(y) + 0.5})
				if d <= craneWorkRadius && d < bestDist {
					bestDist = d
					best = Point{x, y}
				}
			}
		}
	}

	if best.X < 0 {
		// None in range, reposition
		c.State = CranePositioning
		c.findPositioningTarget(s)
		return
	}

	c.CurrentTarget = best

	// Offload trucks
	var sourceTruck *MaterialTruck
	pickUpRange := c.Radius + 30.0
	for _, mt := range c.AssignedTrucks {
		if mt != nil && !mt.IsDespawned() && mt.State == MatAttending && mt.Cargo > 0 {
			if dist2(c.Pos, mt.Pos) <= pickUpRange {
				sourceTruck = mt
				break
			}
		}
	}

	if sourceTruck == nil {
		// Wait for a truck
		return
	}

	// Take material and start placing
	sourceTruck.Cargo--
	log.Printf("[CR#%d] taking material from MT#%d → placing on (%d,%d)",
		c.ID, sourceTruck.ID, c.CurrentTarget.X, c.CurrentTarget.Y)
	if sourceTruck.Cargo == 0 {
		sourceTruck.UnassignFromCrane()
		if s.Grid.PipePlacementCellCount == 0 {
			sourceTruck.State = MatLeaving
		} else {
			sourceTruck.State = MatReturning
		}
		sourceTruck.PathfindTo(s.Grid, s.SpawnCell())
	}
	c.PlaceTimer = 0
	c.PlaceTimerActive = true
}

func (c *Crane) handleLeaving(s *Simulation, dt float32) {
	c.RetryPathfind(s.Grid, s.SpawnCell(), dt)
	c.FollowPath(s.Grid, s.Vehicles, dt)
	if dist2(c.Pos, s.SpawnPos) < 3.0 {
		ClearOccupancy(s.Grid, &c.BaseVehicle)
		c.State = CraneDespawned
	}
}

func (c *Crane) AssignTruck(mt *MaterialTruck) bool {
	for _, t := range c.AssignedTrucks {
		if t == mt {
			return true
		}
	}
	if len(c.AssignedTrucks) < 5 {
		c.AssignedTrucks = append(c.AssignedTrucks, mt)
		return true
	}
	return false
}

func (c *Crane) UnassignTruck(mt *MaterialTruck) {
	for i, t := range c.AssignedTrucks {
		if t == mt {
			c.AssignedTrucks = append(c.AssignedTrucks[:i], c.AssignedTrucks[i+1:]...)
			return
		}
	}
}

func (c *Crane) TruckCount() int {
	return len(c.AssignedTrucks)
}
