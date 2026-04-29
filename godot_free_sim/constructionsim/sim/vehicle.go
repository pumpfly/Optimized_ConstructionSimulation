package sim

import (
	"log"
	"math"
)

type Vec2 struct {
	X, Y float32
}

type VehicleType int

const (
	TypeExcavator VehicleType = iota
	TypeDirtTruck
	TypeCrane
	TypeMaterialTruck
)

type Updatable interface {
	Update(s *Simulation, dt float32)
	GetID() int
	GetPos() Vec2
	GetRadius() float32
	GetType() VehicleType
	IsDespawned() bool
	SetLeaving()
	GetRemainingPath() []Point
}

// jamThreshold is the OthersOccupancy level that triggers a forced standstill.
// jamMaxDuration is the freeze time (seconds) when occupancy is at its worst.
// jamCooldownDuration is the free-movement window after a jam ends, preventing
// the agent from immediately re-jamming on the same tick.
const (
	jamThreshold        = 0.7
	jamMaxDuration      = 8.0
	jamCooldownDuration = 1.0
)

type BaseVehicle struct {
	ID                 int
	Pos                Vec2
	Heading            Vec2 // normalized facing direction, updated while moving
	Radius             float32
	BaseSpeed          float32
	Path               []Point
	PathIdx            int
	Despawned          bool
	SpawnImmunityTicks int
	OccupancyCells     []Point
	PathFailed         bool
	pathRetryTimer     float32
	repathCooldown     float32
	jamTimer           float32 // remaining forced-standstill time
	jamCooldown        float32 // remaining post-jam free-movement window
}

func (b *BaseVehicle) GetID() int         { return b.ID }
func (b *BaseVehicle) GetPos() Vec2       { return b.Pos }
func (b *BaseVehicle) GetRadius() float32 { return b.Radius }
func (b *BaseVehicle) IsDespawned() bool  { return b.Despawned }

func (b *BaseVehicle) GetRemainingPath() []Point {
	if b.PathIdx >= len(b.Path) {
		return nil
	}
	return b.Path[b.PathIdx:]
}

func (b *BaseVehicle) CurrentCell(g *Grid) Point {
	cx := int(b.Pos.X)
	cy := int(b.Pos.Y)
	if cx < 0 {
		cx = 0
	}
	if cx >= g.Width {
		cx = g.Width - 1
	}
	if cy < 0 {
		cy = 0
	}
	if cy >= g.Height {
		cy = g.Height - 1
	}
	return Point{cx, cy}
}

func (b *BaseVehicle) PathfindTo(g *Grid, goal Point) {
	start := b.CurrentCell(g)
	p := g.AStarForVehicle(start, goal, b.ID)
	if p == nil {
		b.PathFailed = true
		b.pathRetryTimer = 0
		b.Path = []Point{start}
		log.Printf("[id=%d] PathfindTo (%d,%d): A* failed (no route from (%d,%d))",
			b.ID, goal.X, goal.Y, start.X, start.Y)
	} else {
		b.PathFailed = false
		b.pathRetryTimer = 0
		b.Path = p
	}
	b.PathIdx = 0
	b.repathCooldown = 0
}

// RetryPathfind calls PathfindTo only when the current path is done.
// If the previous attempt failed (A* found no route), it waits 5 sim-seconds
// before retrying to avoid running a full A* search every tick.
func (b *BaseVehicle) RetryPathfind(g *Grid, goal Point, dt float32) {
	if !b.PathDone() {
		return
	}
	if b.PathFailed {
		b.pathRetryTimer += dt
		if b.pathRetryTimer < 5.0 {
			return
		}
		log.Printf("[id=%d] RetryPathfind (%d,%d): retrying after cooldown", b.ID, goal.X, goal.Y)
	}
	b.PathfindTo(g, goal)
}

func (b *BaseVehicle) FollowPath(g *Grid, idx *SpatialIndex, dt float32) {
	if b.PathIdx >= len(b.Path) {
		return
	}

	// Jam mechanic: when too many agents share the same cell they must stand
	// still for a while, abstractly simulating vehicles reversing and adjusting
	// to fit. The worse the congestion, the longer the freeze.
	if b.jamTimer > 0 {
		b.jamTimer -= dt
		if b.jamTimer <= 0 {
			b.jamCooldown = jamCooldownDuration
		}
		return
	}
	if b.jamCooldown > 0 {
		b.jamCooldown -= dt
	}

	others := g.Cells[b.CurrentCell(g).Y][b.CurrentCell(g).X].OthersOccupancy(b.ID)

	// Lookahead: blend in the occupancy of the next cell on the path so that
	// agents begin slowing down before they enter a congested chokepoint,
	// producing visible queue formation outside bottlenecks.
	if b.PathIdx < len(b.Path) {
		next := b.Path[b.PathIdx]
		nextOcc := g.Cells[next.Y][next.X].OthersOccupancy(b.ID)
		if nextOcc > others {
			others = others*0.4 + nextOcc*0.6
		}
	}

	// Trigger a jam when occupancy exceeds the threshold.
	if b.jamCooldown <= 0 && others > jamThreshold {
		excess := others - jamThreshold
		available := float32(1.0 - jamThreshold)
		if excess > available {
			excess = available
		}
		b.jamTimer = (excess / available) * jamMaxDuration
		return
	}

	// Quadratic slowdown: floor at 5% so agents always make some progress.
	speedMul := (1.0 - others) * (1.0 - others)
	if speedMul < 0.05 {
		speedMul = 0.05
	}
	spd := b.BaseSpeed * speedMul

	target := b.Path[b.PathIdx]
	tx := float32(target.X) + 0.5
	ty := float32(target.Y) + 0.5

	dx := tx - b.Pos.X
	dy := ty - b.Pos.Y
	d := float32(math.Sqrt(float64(dx*dx + dy*dy)))
	if d < 0.3 {
		b.PathIdx++
		return
	}

	// Steering separation: accumulate a push force away from nearby agents.
	var sepX, sepY float32
	for _, other := range idx.Neighbors(b.Pos) {
		if other.GetID() == b.ID || other.IsDespawned() {
			continue
		}
		op := other.GetPos()
		ddx := b.Pos.X - op.X
		ddy := b.Pos.Y - op.Y
		dist := float32(math.Sqrt(float64(ddx*ddx + ddy*ddy)))
		sepDist := b.Radius + other.GetRadius()
		if dist >= sepDist || dist < 0.001 {
			continue
		}
		w := 1.0 - dist/sepDist
		sepX += (ddx / dist) * w
		sepY += (ddy / dist) * w
	}

	const sepStrength = 0.35
	dirX := dx/d + sepX*sepStrength
	dirY := dy/d + sepY*sepStrength
	dirLen := float32(math.Sqrt(float64(dirX*dirX + dirY*dirY)))
	if dirLen > 0.001 {
		dirX /= dirLen
		dirY /= dirLen
	} else {
		dirX = dx / d
		dirY = dy / d
	}

	move := spd * dt
	if move > d {
		move = d
	}
	b.Heading = Vec2{dirX, dirY}

	prevCell := b.CurrentCell(g)
	prevPos := b.Pos
	b.Pos.X += dirX * move
	b.Pos.Y += dirY * move

	// If the separation force pushed us into a cell that is impassable from
	// the previous cell (height diff > 1), revert to only the path-following
	// component to avoid stranding the agent on an unreachable cell.
	newCell := b.CurrentCell(g)
	if newCell != prevCell && !g.edgePassable(prevCell.X, prevCell.Y, newCell.X, newCell.Y) {
		b.Pos = prevPos
		b.Pos.X += (dx / d) * move
		b.Pos.Y += (dy / d) * move
	}
}

func (b *BaseVehicle) CheckRepath(g *Grid, goal Point, dt float32) {
	if b.repathCooldown > 0 {
		b.repathCooldown -= dt
		return
	}
	remaining := len(b.Path) - b.PathIdx
	check := 3
	if check > remaining {
		check = remaining
	}
	for i := 0; i < check; i++ {
		p := b.Path[b.PathIdx+i]
		occ := g.Cells[p.Y][p.X].OthersOccupancy(b.ID)
		if occ > 0.6 {
			// If the blocked cell is the goal itself, push through slowly —
			// rerouting to an occupied destination loops A* every tick.
			if p == goal {
				return
			}
			// Find first clear cell beyond the blockage.
			foundIdx := -1
			var detourGoal Point
			for j := b.PathIdx + i + 1; j < len(b.Path); j++ {
				pp := b.Path[j]
				if g.Cells[pp.Y][pp.X].OthersOccupancy(b.ID) < 0.6 {
					detourGoal = pp
					foundIdx = j
					break
				}
			}
			if foundIdx < 0 {
				// All remaining cells blocked — push through, don't loop A*.
				return
			}
			cur := b.CurrentCell(g)
			detour := g.AStarForVehicle(cur, detourGoal, b.ID)
			if detour != nil {
				log.Printf("[id=%d] detour repath: blocked at (%d,%d) occ=%.2f → detour to (%d,%d) len=%d",
					b.ID, p.X, p.Y, occ, detourGoal.X, detourGoal.Y, len(detour))
				// Append the tail of the original path after the detour goal
				// so the vehicle continues to the actual destination.
				detour = append(detour, b.Path[foundIdx+1:]...)
				b.Path = detour
				b.PathIdx = 0
				b.repathCooldown = 3.0 // sim-seconds before next occupancy repath
			} else {
				log.Printf("[id=%d] detour repath: blocked at (%d,%d) occ=%.2f → A* failed to (%d,%d), pushing through",
					b.ID, p.X, p.Y, occ, detourGoal.X, detourGoal.Y)
				b.repathCooldown = 3.0
			}
			return
		}
	}
}

func (b *BaseVehicle) AtGoal(goal Vec2, threshold float32) bool {
	return dist2(b.Pos, goal) < threshold
}

func (b *BaseVehicle) PathDone() bool {
	return b.PathIdx >= len(b.Path)
}

func CellCenter(p Point) Vec2 {
	return Vec2{float32(p.X) + 0.5, float32(p.Y) + 0.5}
}
