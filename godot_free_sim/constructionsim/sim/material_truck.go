package sim

type MatTruckState int

const (
	MatSpawned MatTruckState = iota
	MatWaitingForPhase2
	MatSearching
	MatMovingToCrane
	MatAttending
	MatReturning
	MatRestocking
	MatLeaving
	MatDespawned
)

type MaterialTruck struct {
	BaseVehicle
	State         MatTruckState
	Cargo         int
	AssignedCrane *Crane
	RestockTimer  float32
	SearchTimer   float32
	WanderTarget  Point
	IsWandering   bool
	followTarget  Point // last A* goal used in handleAttending
}

func NewMaterialTruck(id int, spawnPos Vec2) *MaterialTruck {
	return &MaterialTruck{
		BaseVehicle: BaseVehicle{
			ID:                 id,
			Pos:                spawnPos,
			Radius:             2,
			BaseSpeed:          4.0,
			SpawnImmunityTicks: 20,
		},
		State: MatSpawned,
		Cargo: 2,
	}
}

func (m *MaterialTruck) GetType() VehicleType { return TypeMaterialTruck }

func (m *MaterialTruck) SetLeaving() {
	if m.State != MatDespawned {
		m.UnassignFromCrane()
		m.State = MatLeaving
		m.Path = nil
		m.PathIdx = 0
	}
}

func (m *MaterialTruck) IsDespawned() bool { return m.State == MatDespawned }

func (m *MaterialTruck) UnassignFromCrane() {
	if m.AssignedCrane != nil {
		m.AssignedCrane.UnassignTruck(m)
		m.AssignedCrane = nil
	}
}

func (m *MaterialTruck) Update(s *Simulation, dt float32) {
	if m.SpawnImmunityTicks > 0 {
		m.SpawnImmunityTicks--
	}
	UpdateOccupancy(s.Grid, &m.BaseVehicle)

	switch m.State {
	case MatSpawned:
		if s.Phase.Phase2Complete {
			m.State = MatLeaving
		} else {
			m.handleSpawned(s)
		}
	case MatWaitingForPhase2:
		m.handleWaiting(s, dt)
	case MatSearching:
		m.handleSearching(s, dt)
	case MatMovingToCrane:
		m.handleMovingToCrane(s, dt)
	case MatAttending:
		m.handleAttending(s, dt)
	case MatReturning:
		m.handleLeavingForNewPipes(s, dt)
	case MatRestocking:
		m.handleRestocking(s, dt, s.Grid.PipePlacementCellCount)
	case MatLeaving:
		m.handleLeaving(s, dt)
	}
}

func (m *MaterialTruck) handleSpawned(s *Simulation) {
	if s.Grid.PipePlacementCellCount > 1 {
		m.BaseSpeed = 3.0
		s.Grid.PipePlacementCellCount -= 2
	} else if s.Grid.PipePlacementCellCount == 1 {
		m.BaseSpeed = 4.0
		s.Grid.PipePlacementCellCount -= 1
		m.Cargo = 1
	} else {
		m.BaseSpeed = 5.0
		m.Cargo = 0
		m.State = MatLeaving
		return
	}
	if !s.Phase.Phase1Complete {
		target := s.WanderTarget(m.ID, 5, 15)
		m.WanderTarget = target
		m.IsWandering = false
		m.PathfindTo(s.Grid, target)
		m.State = MatWaitingForPhase2
		return
	}
	m.State = MatSearching
	m.searchCrane(s)
}

func (m *MaterialTruck) handleWaiting(s *Simulation, dt float32) {
	m.FollowPath(s.Grid, s.spatialIdx, dt)
	if s.Phase.Phase1Complete {
		m.State = MatSearching
		m.searchCrane(s)
	}
}

func (m *MaterialTruck) searchCrane(s *Simulation) {
	for _, v := range s.Vehicles {
		cr, ok := v.(*Crane)
		if !ok || cr.IsDespawned() {
			continue
		}
		if cr.AssignTruck(m) {
			m.AssignedCrane = cr
			m.PathfindTo(s.Grid, cr.CurrentCell(s.Grid))
			m.State = MatMovingToCrane
			return
		}
	}

	// Not assigned — wander only if near spawn, otherwise stay put and wait
	m.SearchTimer = 0
	if dist2(m.Pos, s.SpawnPos) < 3.0 {
		m.IsWandering = true
		target := s.WanderTarget(m.ID, 5, 15)
		m.WanderTarget = target
		m.PathfindTo(s.Grid, target)
	}
}

func (m *MaterialTruck) handleSearching(s *Simulation, dt float32) {
	if m.IsWandering {
		m.FollowPath(s.Grid, s.spatialIdx, dt)
		if m.PathDone() {
			m.IsWandering = false
		}
		m.SearchTimer += dt
		if m.SearchTimer >= 15.0 {
			m.IsWandering = false
			m.searchCrane(s)
		}
		return
	}
	m.SearchTimer += dt
	if m.SearchTimer >= 15.0 {
		m.SearchTimer = 0
		m.searchCrane(s)
	}
}

func (m *MaterialTruck) handleMovingToCrane(s *Simulation, dt float32) {
	if m.AssignedCrane == nil || m.AssignedCrane.IsDespawned() {
		m.AssignedCrane = nil
		m.State = MatSearching
		m.SearchTimer = 0
		return
	}
	m.RetryPathfind(s.Grid, m.AssignedCrane.CurrentCell(s.Grid), dt)
	m.CheckRepath(s.Grid, m.AssignedCrane.CurrentCell(s.Grid), dt)
	m.FollowPath(s.Grid, s.spatialIdx, dt)
	attendDist := m.AssignedCrane.Radius + m.Radius + 10
	if dist2(m.Pos, m.AssignedCrane.Pos) <= attendDist+5.0 {
		m.State = MatAttending
	}
}

func (m *MaterialTruck) handleAttending(s *Simulation, dt float32) {
	if m.AssignedCrane == nil || m.AssignedCrane.IsDespawned() {
		m.AssignedCrane = nil
		m.State = MatSearching
		m.SearchTimer = 0
		return
	}

	// Maintain standoff distance.
	attendDist := m.AssignedCrane.Radius + m.Radius
	if dist2(m.Pos, m.AssignedCrane.Pos) <= attendDist {
		return
	}

	// Route via the crane's trail so the path respects walls.
	goal := m.AssignedCrane.CurrentCell(s.Grid)
	if trail := m.AssignedCrane.Trail; len(trail) > 0 {
		goal = trail[len(trail)-1]
	}

	if goal != m.followTarget || m.PathDone() {
		m.followTarget = goal
		m.PathfindTo(s.Grid, goal)
	}
	m.CheckRepath(s.Grid, goal, dt)
	m.FollowPath(s.Grid, s.spatialIdx, dt)
	// Cargo deducted by crane when it takes material
}

func (m *MaterialTruck) handleLeavingForNewPipes(s *Simulation, dt float32) {
	m.BaseSpeed = 5.0
	m.CheckRepath(s.Grid, s.SpawnCell(), dt)
	m.FollowPath(s.Grid, s.spatialIdx, dt)
	if dist2(m.Pos, s.SpawnPos) < 3.0 {
		m.State = MatRestocking
		m.RestockTimer = 0
	}
}

func (m *MaterialTruck) handleRestocking(s *Simulation, dt float32, stockCount int) {
	m.RestockTimer += dt
	if m.RestockTimer >= 1800.0 { // The stock place for pipes is about 15 minutes away + return time
		if stockCount > 1 {
			m.BaseSpeed = 3.0
			m.Cargo = 2
			s.Grid.PipePlacementCellCount -= 2
		} else if stockCount == 1 {
			m.BaseSpeed = 4.0
			m.Cargo = 1
			s.Grid.PipePlacementCellCount -= 1
		} else {
			m.BaseSpeed = 5.0
			m.State = MatLeaving
			return
		}

		m.State = MatSearching
		m.SearchTimer = 0
		m.searchCrane(s)
	}
}

func (m *MaterialTruck) handleLeaving(s *Simulation, dt float32) {
	m.BaseSpeed = 5.0
	m.RetryPathfind(s.Grid, s.SpawnCell(), dt)
	m.FollowPath(s.Grid, s.spatialIdx, dt)
	if dist2(m.Pos, s.SpawnPos) < 3.0 {
		ClearOccupancy(s.Grid, &m.BaseVehicle)
		m.State = MatDespawned
	}
}
