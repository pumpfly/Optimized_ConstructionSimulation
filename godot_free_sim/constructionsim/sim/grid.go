package sim

import (
	"container/heap"
	"fmt"
	"image"
	_ "image/png"
	"math"
	"os"
)

type Point struct {
	X, Y int
}

type Cell struct {
	Height            float32
	InitialHeight     float32
	Excavate          bool
	PipePlacementCell bool
	ExcavDone         bool
	ConstrDone        bool
	Reserved          int
	Occupancy         map[int]float32
}

type Grid struct {
	Width, Height          int
	Cells                  [][]Cell
	Spawn                  Point
	InitialPPCCount        int
	PipePlacementCellCount int
}

func LoadGrid(path string) (*Grid, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open heightmap: %w", err)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		return nil, fmt.Errorf("decode heightmap: %w", err)
	}

	bounds := img.Bounds()
	w := bounds.Max.X - bounds.Min.X
	h := bounds.Max.Y - bounds.Min.Y

	g := &Grid{Width: w, Height: h}
	g.Cells = make([][]Cell, h)
	spawnFound := false
	for y := 0; y < h; y++ {
		g.Cells[y] = make([]Cell, w)
		for x := 0; x < w; x++ {
			r, gr, b, _ := img.At(bounds.Min.X+x, bounds.Min.Y+y).RGBA()
			rv := uint8(r >> 8)
			gv := uint8(gr >> 8)
			bv := uint8(b >> 8)
			c := &g.Cells[y][x]
			c.Height = float32(bv)
			c.InitialHeight = float32(bv)
			c.Excavate = rv > 0
			if gv > 0 && gv != 255 {
				c.PipePlacementCell = true
				g.PipePlacementCellCount++
			}
			c.Reserved = -1
			c.Occupancy = make(map[int]float32)
			if gv == 255 {
				g.Spawn = Point{x, y}
				spawnFound = true
			}
		}
	}
	g.InitialPPCCount = g.PipePlacementCellCount
	if !spawnFound {
		return nil, fmt.Errorf("heightmap has no spawn cell (no pixel with green=255)")
	}
	return g, nil
}

func (g *Grid) At(x, y int) *Cell {
	return &g.Cells[y][x]
}

func (g *Grid) InBounds(x, y int) bool {
	return x >= 0 && x < g.Width && y >= 0 && y < g.Height
}

func (g *Grid) edgePassable(ax, ay, bx, by int) bool {
	if !g.InBounds(ax, ay) || !g.InBounds(bx, by) {
		return false
	}
	ha := g.Cells[ay][ax].Height
	hb := g.Cells[by][bx].Height
	return abs32(ha-hb) <= 1
}

func abs32(v float32) float32 {
	if v < 0 {
		return -v
	}
	return v
}

type astarNode struct {
	p    Point
	g, f float32
	idx  int
}

type astarHeap []*astarNode

func (h astarHeap) Len() int            { return len(h) }
func (h astarHeap) Less(i, j int) bool  { return h[i].f < h[j].f }
func (h astarHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i]; h[i].idx = i; h[j].idx = j }
func (h *astarHeap) Push(x interface{}) { n := x.(*astarNode); n.idx = len(*h); *h = append(*h, n) }
func (h *astarHeap) Pop() interface{} {
	old := *h
	n := old[len(old)-1]
	*h = old[:len(old)-1]
	return n
}

var dirs = []struct {
	dx, dy   int
	cost     float32
	diagonal bool
}{
	{1, 0, 1.0, false},
	{-1, 0, 1.0, false},
	{0, 1, 1.0, false},
	{0, -1, 1.0, false},
	{1, 1, float32(math.Sqrt2), true},
	{1, -1, float32(math.Sqrt2), true},
	{-1, 1, float32(math.Sqrt2), true},
	{-1, -1, float32(math.Sqrt2), true},
}

func (g *Grid) AStarForVehicle(start, goal Point, vehicleID int) []Point {
	if !g.InBounds(start.X, start.Y) || !g.InBounds(goal.X, goal.Y) {
		return nil
	}
	if start == goal {
		return []Point{start}
	}

	type nodeKey struct{ x, y int }
	gScore := map[nodeKey]float32{}
	came := map[nodeKey]nodeKey{}

	startKey := nodeKey{start.X, start.Y}
	gScore[startKey] = 0

	heuristic := func(p Point) float32 {
		dx := float32(p.X - goal.X)
		dy := float32(p.Y - goal.Y)
		return float32(math.Sqrt(float64(dx*dx + dy*dy)))
	}

	open := &astarHeap{}
	heap.Init(open)
	heap.Push(open, &astarNode{p: start, g: 0, f: heuristic(start)})

	for open.Len() > 0 {
		cur := heap.Pop(open).(*astarNode)
		// Skip stale heap entries (a better path was found after this was pushed).
		if best, ok := gScore[nodeKey{cur.p.X, cur.p.Y}]; ok && cur.g > best {
			continue
		}
		if cur.p == goal {
			var path []Point
			k := nodeKey{cur.p.X, cur.p.Y}
			for k != startKey {
				path = append(path, Point{k.x, k.y})
				k = came[k]
			}
			path = append(path, start)
			for i, j := 0, len(path)-1; i < j; i, j = i+1, j-1 {
				path[i], path[j] = path[j], path[i]
			}
			return path
		}

		ck := nodeKey{cur.p.X, cur.p.Y}
		for _, d := range dirs {
			nx, ny := cur.p.X+d.dx, cur.p.Y+d.dy
			if !g.InBounds(nx, ny) {
				continue
			}
			if !g.edgePassable(cur.p.X, cur.p.Y, nx, ny) {
				continue
			}
			if d.diagonal {
				if !g.edgePassable(cur.p.X, cur.p.Y, nx, cur.p.Y) ||
					!g.edgePassable(cur.p.X, cur.p.Y, cur.p.X, ny) {
					continue
				}
			}

			occ := g.Cells[ny][nx].OthersOccupancy(vehicleID)
			cost := d.cost * (1 + occ*20)

			nk := nodeKey{nx, ny}
			ng := cur.g + cost
			if prev, ok := gScore[nk]; !ok || ng < prev {
				gScore[nk] = ng
				came[nk] = ck
				f := ng + heuristic(Point{nx, ny})
				heap.Push(open, &astarNode{p: Point{nx, ny}, g: ng, f: f})
			}
		}
	}
	return nil
}

// Reset restores all mutable cell state so the grid can be reused across simulation runs.
func (g *Grid) Reset() {
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			c := &g.Cells[y][x]
			c.Height = c.InitialHeight
			c.ExcavDone = false
			c.ConstrDone = false
			c.Reserved = -1
			for k := range c.Occupancy {
				delete(c.Occupancy, k)
			}
		}
	}
	g.PipePlacementCellCount = g.InitialPPCCount
}

func (g *Grid) UpdateEdgesAround(cx, cy int) {
	// Edge passability is computed on demand from cell heights.
	// Nothing stored to update here — edgePassable reads live height values.
}

func (c *Cell) OthersOccupancy(vehicleID int) float32 {
	var total float32
	for id, v := range c.Occupancy {
		if id != vehicleID {
			total += v
		}
	}
	return total
}

// TotalOccupancy returns the sum of all occupancy contributions on this cell,
// clamped to [0, 1]. Used for visual tinting.
func (c *Cell) TotalOccupancy() float32 {
	var total float32
	for _, v := range c.Occupancy {
		total += v
	}
	if total > 1 {
		total = 1
	}
	return total
}
