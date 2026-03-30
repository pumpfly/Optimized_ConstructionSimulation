package sim

import "math"

const SyntheticExcavID = math.MinInt32

// Occupancy of Cells from Agents

func UpdateOccupancy(g *Grid, v *BaseVehicle) {
	// Clear old entries
	for _, p := range v.OccupancyCells {
		if g.InBounds(p.X, p.Y) {
			delete(g.Cells[p.Y][p.X].Occupancy, v.ID)
		}
	}
	v.OccupancyCells = v.OccupancyCells[:0]

	if v.SpawnImmunityTicks > 0 {
		return
	}

	r := v.Radius
	cx := int(v.Pos.X)
	cy := int(v.Pos.Y)
	ri := int(math.Ceil(float64(r)))

	for dy := -ri; dy <= ri; dy++ {
		for dx := -ri; dx <= ri; dx++ {
			nx, ny := cx+dx, cy+dy
			if !g.InBounds(nx, ny) {
				continue
			}
			// Skip cells that are not part of the drivable surface (no passable
			// edge to any neighbour means agents cannot traverse there).
			drivable := false
			for _, d := range [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} {
				ax, ay := nx+d[0], ny+d[1]
				if g.InBounds(ax, ay) && g.edgePassable(nx, ny, ax, ay) {
					drivable = true
					break
				}
			}
			if !drivable {
				continue
			}
			cellCX := float32(nx) + 0.5
			cellCY := float32(ny) + 0.5
			dist := dist2(v.Pos, Vec2{cellCX, cellCY})
			if dist >= r {
				continue
			}
			contrib := 1.0 - dist/r
			if contrib < 0 {
				contrib = 0
			}
			if contrib > 1 {
				contrib = 1
			}
			g.Cells[ny][nx].Occupancy[v.ID] = contrib
			v.OccupancyCells = append(v.OccupancyCells, Point{nx, ny})
		}
	}
}

func ClearOccupancy(g *Grid, v *BaseVehicle) {
	for _, p := range v.OccupancyCells {
		if g.InBounds(p.X, p.Y) {
			delete(g.Cells[p.Y][p.X].Occupancy, v.ID)
		}
	}
	v.OccupancyCells = v.OccupancyCells[:0]
}

func dist2(a, b Vec2) float32 {
	dx := a.X - b.X
	dy := a.Y - b.Y
	return float32(math.Sqrt(float64(dx*dx + dy*dy)))
}
