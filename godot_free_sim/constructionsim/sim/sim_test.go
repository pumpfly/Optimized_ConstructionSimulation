package sim

import "testing"

// ---- helpers ----

func makeGrid(w, h int, height float32) *Grid {
	g := &Grid{Width: w, Height: h, Cells: make([][]Cell, h)}
	for y := 0; y < h; y++ {
		g.Cells[y] = make([]Cell, w)
		for x := 0; x < w; x++ {
			c := &g.Cells[y][x]
			c.Height = height
			c.InitialHeight = height
			c.Reserved = -1
			c.Occupancy = make(map[int]float32)
		}
	}
	return g
}

func setHeight(g *Grid, x, y int, h float32) {
	g.Cells[y][x].Height = h
	g.Cells[y][x].InitialHeight = h
}

// ---- A* ----

func TestAStarFindsPath(t *testing.T) {
	g := makeGrid(5, 5, 10)
	path := g.AStarForVehicle(Point{0, 0}, Point{4, 4}, -1)
	if path == nil {
		t.Fatal("expected path on flat grid, got nil")
	}
	if path[0] != (Point{0, 0}) {
		t.Errorf("path start: want {0,0}, got %v", path[0])
	}
	if path[len(path)-1] != (Point{4, 4}) {
		t.Errorf("path end: want {4,4}, got %v", path[len(path)-1])
	}
}

func TestAStarSameStartGoal(t *testing.T) {
	g := makeGrid(3, 3, 10)
	path := g.AStarForVehicle(Point{1, 1}, Point{1, 1}, -1)
	if len(path) != 1 || path[0] != (Point{1, 1}) {
		t.Errorf("want [{1 1}], got %v", path)
	}
}

func TestAStarHeightDiffOneIsPassable(t *testing.T) {
	// Spec: abs(ha - hb) <= 1 is passable.
	g := makeGrid(3, 1, 10)
	setHeight(g, 1, 0, 11)
	path := g.AStarForVehicle(Point{0, 0}, Point{2, 0}, -1)
	if path == nil {
		t.Fatal("height diff of 1 should be passable")
	}
}

func TestAStarHeightDiffTwoBlocks(t *testing.T) {
	g := makeGrid(3, 1, 10)
	setHeight(g, 1, 0, 12)
	path := g.AStarForVehicle(Point{0, 0}, Point{2, 0}, -1)
	if path != nil {
		t.Errorf("height diff of 2 should block, got %v", path)
	}
}

func TestAStarWallBlocks(t *testing.T) {
	// 1×5 corridor; cliff at column 2 — only possible path is blocked.
	g := makeGrid(5, 1, 10)
	setHeight(g, 2, 0, 100)
	path := g.AStarForVehicle(Point{0, 0}, Point{4, 0}, -1)
	if path != nil {
		t.Errorf("expected nil through height wall, got %v", path)
	}
}

func TestAStarGoesAroundPartialWall(t *testing.T) {
	// 5×3; wall at col 2 rows 0–1, gap at row 2 — path must detour.
	g := makeGrid(5, 3, 10)
	setHeight(g, 2, 0, 100)
	setHeight(g, 2, 1, 100)
	path := g.AStarForVehicle(Point{0, 0}, Point{4, 0}, -1)
	if path == nil {
		t.Fatal("expected path around partial wall, got nil")
	}
	if path[len(path)-1] != (Point{4, 0}) {
		t.Errorf("path end: want {4,0}, got %v", path[len(path)-1])
	}
}

func TestAStarNoDiagonalCornerCut(t *testing.T) {
	// 2×2 grid; the only link between (0,0) and (1,1) is the diagonal, but
	// both shared orthogonal neighbours are walls — so the diagonal must be
	// blocked, leaving no path at all.
	//
	//  S  W
	//  W  G
	g := makeGrid(2, 2, 10)
	setHeight(g, 1, 0, 100) // right of S
	setHeight(g, 0, 1, 100) // below S
	path := g.AStarForVehicle(Point{0, 0}, Point{1, 1}, -1)
	if path != nil {
		t.Errorf("diagonal corner-cut must be blocked, got %v", path)
	}
}

func TestAStarPathIsContiguous(t *testing.T) {
	// Every step in the returned path must be a valid neighbour (max 1 cell apart).
	g := makeGrid(8, 8, 10)
	path := g.AStarForVehicle(Point{0, 0}, Point{7, 7}, -1)
	if path == nil {
		t.Fatal("expected path")
	}
	for i := 1; i < len(path); i++ {
		dx := path[i].X - path[i-1].X
		dy := path[i].Y - path[i-1].Y
		if dx < -1 || dx > 1 || dy < -1 || dy > 1 {
			t.Errorf("non-adjacent step at index %d: %v → %v", i, path[i-1], path[i])
		}
	}
}

// ---- Grid.Reset ----

func TestGridResetRestoresState(t *testing.T) {
	g := makeGrid(3, 3, 10)

	// Simulate mutations a simulation run would make.
	g.Cells[1][1].Height = 9
	g.Cells[1][1].ExcavDone = true
	g.Cells[0][0].ConstrDone = true
	g.Cells[2][2].Reserved = 42
	g.Cells[0][2].Occupancy[7] = 0.8

	g.Reset()

	if g.Cells[1][1].Height != 10 {
		t.Errorf("Height not restored: got %v", g.Cells[1][1].Height)
	}
	if g.Cells[1][1].ExcavDone {
		t.Error("ExcavDone not cleared")
	}
	if g.Cells[0][0].ConstrDone {
		t.Error("ConstrDone not cleared")
	}
	if g.Cells[2][2].Reserved != -1 {
		t.Errorf("Reserved not reset: got %v", g.Cells[2][2].Reserved)
	}
	if len(g.Cells[0][2].Occupancy) != 0 {
		t.Errorf("Occupancy not cleared: %v", g.Cells[0][2].Occupancy)
	}
}

func TestGridResetPreservesStaticFields(t *testing.T) {
	g := makeGrid(2, 2, 10)
	g.Cells[0][0].Excavate = true
	g.Cells[1][1].PipePlacementCell = true
	g.Cells[0][1].Height = 5
	g.Cells[0][1].InitialHeight = 5

	g.Reset()

	if !g.Cells[0][0].Excavate {
		t.Error("Excavate flag should survive Reset")
	}
	if !g.Cells[1][1].PipePlacementCell {
		t.Error("Construct flag should survive Reset")
	}
	if g.Cells[0][1].Height != 5 {
		t.Errorf("InitialHeight 5 should be restored to 5, got %v", g.Cells[0][1].Height)
	}
}

// ---- Occupancy ----

func TestOccupancyContribution(t *testing.T) {
	// Vehicle at (3.5, 3.5), radius 2.0.
	//   Cell (3,3): center (3.5,3.5), dist=0   → contribution 1.0
	//   Cell (4,3): center (4.5,3.5), dist=1.0 → contribution 0.5
	//   Cell (5,3): center (5.5,3.5), dist=2.0 → excluded (dist >= r)
	g := makeGrid(7, 7, 10)
	v := &BaseVehicle{ID: 1, Pos: Vec2{3.5, 3.5}, Radius: 2.0}

	UpdateOccupancy(g, v)

	if got := g.Cells[3][3].Occupancy[1]; got != 1.0 {
		t.Errorf("center cell: want 1.0, got %v", got)
	}
	if got, want := g.Cells[3][4].Occupancy[1], float32(0.5); abs32(got-want) > 1e-5 {
		t.Errorf("adjacent cell: want %v, got %v", want, got)
	}
	if _, ok := g.Cells[3][5].Occupancy[1]; ok {
		t.Error("cell at exactly r should not receive occupancy")
	}
}

func TestOccupancySpawnImmunitySuppressesWrites(t *testing.T) {
	g := makeGrid(5, 5, 10)
	v := &BaseVehicle{ID: 2, Pos: Vec2{2.5, 2.5}, Radius: 1.0, SpawnImmunityTicks: 1}

	UpdateOccupancy(g, v)

	if len(g.Cells[2][2].Occupancy) != 0 {
		t.Error("vehicle with spawn immunity should not write occupancy")
	}
}

func TestOccupancyDirtyTracking(t *testing.T) {
	// After moving, old cell entries must be cleared and new ones written.
	g := makeGrid(7, 7, 10)
	v := &BaseVehicle{ID: 3, Pos: Vec2{1.5, 1.5}, Radius: 1.0}

	UpdateOccupancy(g, v)
	firstCells := make([]Point, len(v.OccupancyCells))
	copy(firstCells, v.OccupancyCells)

	v.Pos = Vec2{5.5, 5.5}
	UpdateOccupancy(g, v)

	for _, p := range firstCells {
		if _, ok := g.Cells[p.Y][p.X].Occupancy[3]; ok {
			t.Errorf("stale occupancy at %v not cleared after move", p)
		}
	}
	// New position must have occupancy.
	if g.Cells[5][5].Occupancy[3] != 1.0 {
		t.Errorf("new center cell: want 1.0, got %v", g.Cells[5][5].Occupancy[3])
	}
}

func TestOccupancyOthersExcludesSelf(t *testing.T) {
	g := makeGrid(3, 3, 10)
	g.Cells[1][1].Occupancy[10] = 0.8 // vehicle 10
	g.Cells[1][1].Occupancy[20] = 0.5 // vehicle 20

	if got := g.Cells[1][1].OthersOccupancy(10); abs32(got-0.5) > 1e-5 {
		t.Errorf("OthersOccupancy(10): want 0.5, got %v", got)
	}
	if got := g.Cells[1][1].OthersOccupancy(99); abs32(got-1.3) > 1e-5 {
		t.Errorf("OthersOccupancy(unknown): want 1.3, got %v", got)
	}
}

// ---- Phase manager ----

func TestPhaseManagerCounts(t *testing.T) {
	g := makeGrid(3, 3, 10)
	g.Cells[0][0].Excavate = true
	g.Cells[0][1].Excavate = true
	g.Cells[1][0].PipePlacementCell = true

	pm := NewPhaseManager(g)
	if pm.TotalExcavation != 2 {
		t.Errorf("TotalExcavation: want 2, got %d", pm.TotalExcavation)
	}
	if pm.TotalConstruct != 1 {
		t.Errorf("TotalConstruct: want 1, got %d", pm.TotalConstruct)
	}
}

func TestPhaseManagerPhase1Progression(t *testing.T) {
	g := makeGrid(2, 1, 10)
	g.Cells[0][0].Excavate = true
	g.Cells[0][1].Excavate = true
	pm := NewPhaseManager(g)

	if pm.CheckPhase1(1) {
		t.Error("phase 1 should not complete with 0/2 done")
	}
	pm.RecordExcavation(5)
	if pm.CheckPhase1(10) {
		t.Error("phase 1 should not complete with 1/2 done")
	}
	pm.RecordExcavation(15)
	if !pm.CheckPhase1(20) {
		t.Error("phase 1 should complete with 2/2 done")
	}
	if pm.Phase1CompleteAt != 20 {
		t.Errorf("Phase1CompleteAt: want 20, got %v", pm.Phase1CompleteAt)
	}
	// Idempotent.
	if pm.CheckPhase1(25) {
		t.Error("CheckPhase1 must be idempotent after completion")
	}
}

func TestPhaseManagerZeroExcavation(t *testing.T) {
	g := makeGrid(2, 2, 10) // no excavation cells
	pm := NewPhaseManager(g)
	if !pm.CheckPhase1(0) {
		t.Error("zero excavation cells should complete phase 1 immediately")
	}
}

func TestPhaseManagerPhase2RequiresPhase1(t *testing.T) {
	g := makeGrid(2, 1, 10)
	g.Cells[0][0].PipePlacementCell = true
	pm := NewPhaseManager(g)
	pm.RecordConstruction(5)
	// Phase 1 not marked complete.
	if pm.CheckPhase2(5) {
		t.Error("phase 2 must not complete while phase 1 is pending")
	}
}

func TestPhaseManagerPhase2Progression(t *testing.T) {
	g := makeGrid(2, 1, 10)
	g.Cells[0][0].PipePlacementCell = true
	g.Cells[0][1].PipePlacementCell = true
	pm := NewPhaseManager(g)
	pm.Phase1Complete = true
	pm.Phase1CompleteAt = 10

	pm.RecordConstruction(15)
	if pm.CheckPhase2(20) {
		t.Error("phase 2 should not complete with 1/2 done")
	}
	pm.RecordConstruction(25)
	if !pm.CheckPhase2(30) {
		t.Error("phase 2 should complete with 2/2 done")
	}
	if pm.Phase2CompleteAt != 30 {
		t.Errorf("Phase2CompleteAt: want 30, got %v", pm.Phase2CompleteAt)
	}
}
