package render

import (
	"constructionsim/sim"
	"fmt"
	"math"

	rl "github.com/gen2brain/raylib-go/raylib"
)

// materialColor is the warm amber used for cargo cubes and placed material.
var materialColor = rl.Color{R: 240, G: 180, B: 60, A: 255}

type Renderer struct {
	camera             rl.Camera3D
	width              int32
	height             int32
	orbitAngle         float32  // horizontal angle, radians
	orbitElev          float32  // elevation angle, radians
	orbitDist          float32  // distance from target
	autoOrbit          bool     // whether auto-spin is active
	Paused             bool     // simulation pause toggle ([P] key)
	materialModel      rl.Model // unit cube used with DrawModelEx so we can rotate it
	excavatorModel     rl.Model
	dirtTruckModel     rl.Model
	craneModel         rl.Model
	materialTruckModel rl.Model
	pipesModel         rl.Model
}

func NewRenderer(width, height int, g *sim.Grid) *Renderer {
	r := &Renderer{
		width:      int32(width),
		height:     int32(height),
		orbitDist:  120,
		orbitElev:  0.55, // ~31° above horizon
		orbitAngle: 0,
		autoOrbit:  false,
	}
	rl.InitWindow(r.width, r.height, "Construction Simulation")
	rl.SetTargetFPS(60)
	cx := float32(g.Width) / 2
	cz := float32(g.Height) / 2
	cy := g.At(g.Width/2, g.Height/2).Height
	r.camera = rl.Camera3D{
		Target:     rl.Vector3{X: cx, Y: cy, Z: cz},
		Up:         rl.Vector3{X: 0, Y: 1, Z: 0},
		Fovy:       45,
		Projection: rl.CameraPerspective,
	}
	r.updateCameraPosition()
	// Build the rotatable cube model after the GL context is ready.
	r.materialModel = rl.LoadModelFromMesh(rl.GenMeshCube(1, 1, 1))
	// Load vehicle models once after the GL context is ready.
	r.excavatorModel = rl.LoadModel("assets/bagger.glb")
	r.dirtTruckModel = rl.LoadModel("assets/LKW.glb")
	r.craneModel = rl.LoadModel("assets/Kran.glb")
	r.materialTruckModel = rl.LoadModel("assets/LKW_with_material.glb")
	r.pipesModel = rl.LoadModel("assets/pipes.glb")
	return r
}

// updateCameraPosition recomputes camera.Position from spherical coords.
func (r *Renderer) updateCameraPosition() {
	t := r.camera.Target
	r.camera.Position = rl.Vector3{
		X: t.X + r.orbitDist*float32(math.Cos(float64(r.orbitElev)))*float32(math.Cos(float64(r.orbitAngle))),
		Y: t.Y + r.orbitDist*float32(math.Sin(float64(r.orbitElev))),
		Z: t.Z + r.orbitDist*float32(math.Cos(float64(r.orbitElev)))*float32(math.Sin(float64(r.orbitAngle))),
	}
}

func (r *Renderer) ShouldClose() bool {
	return rl.WindowShouldClose()
}

func (r *Renderer) GetFrameTime() float32 {
	return rl.GetFrameTime()
}

func (r *Renderer) Draw(s *sim.Simulation) {
	dt := rl.GetFrameTime()

	// [P] toggles simulation pause.
	if rl.IsKeyPressed(rl.KeyP) {
		r.Paused = !r.Paused
	}

	// [O] toggles auto-orbit.
	if rl.IsKeyPressed(rl.KeyO) {
		r.autoOrbit = !r.autoOrbit
	}

	// Auto-orbit: slowly spin the camera around the target.
	if r.autoOrbit {
		r.orbitAngle += dt * 0.3
	}

	// Mouse drag (left button) to orbit manually.
	if rl.IsMouseButtonDown(rl.MouseButtonLeft) {
		delta := rl.GetMouseDelta()
		r.orbitAngle += delta.X * 0.005
		r.orbitElev += delta.Y * 0.005
		if r.orbitElev > 1.5 {
			r.orbitElev = 1.5
		}
		if r.orbitElev < 0.05 {
			r.orbitElev = 0.05
		}
	}

	// Scroll wheel to zoom.
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		r.orbitDist -= wheel * 5
		if r.orbitDist < 10 {
			r.orbitDist = 10
		}
		if r.orbitDist > 400 {
			r.orbitDist = 400
		}
	}

	// [UP]/[DOWN] arrows shift the look-at target (and camera) vertically.
	// [LEFT]/[RIGHT] arrows pan the target horizontally perpendicular to the view.
	panSpeed := float32(60.0) * dt
	if rl.IsKeyDown(rl.KeyUp) {
		r.camera.Target.Y += panSpeed
	}
	if rl.IsKeyDown(rl.KeyDown) {
		r.camera.Target.Y -= panSpeed
	}
	rightX := float32(math.Sin(float64(r.orbitAngle)))
	rightZ := float32(-math.Cos(float64(r.orbitAngle)))
	if rl.IsKeyDown(rl.KeyLeft) {
		r.camera.Target.X -= rightX * panSpeed
		r.camera.Target.Z -= rightZ * panSpeed
	}
	if rl.IsKeyDown(rl.KeyRight) {
		r.camera.Target.X += rightX * panSpeed
		r.camera.Target.Z += rightZ * panSpeed
	}

	r.updateCameraPosition()

	rl.BeginDrawing()
	rl.ClearBackground(rl.Color{R: 100, G: 140, B: 180, A: 255}) // sky blue

	rl.BeginMode3D(r.camera)

	g := s.Grid
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			c := g.At(x, y)
			h := c.Height

			// Base colour encodes cell purpose / completion state.
			v := uint8(100 + int(h-60)*2) // 60→100, 80→140, 100→180
			base := rl.Color{R: v, G: v, B: v, A: 255}
			switch {
			case c.ConstrDone:
				base = rl.Color{R: 60, G: 110, B: 60, A: 255} // dark green — built
			case c.PipePlacementCell && !c.ConstrDone:
				base = rl.Color{R: 80, G: 160, B: 80, A: 255} // green — pending build
			case c.Excavate && !c.ExcavDone:
				base = rl.Color{R: 180, G: 90, B: 90, A: 255} // red — pending dig
			}

			// Tint toward blue based on total occupancy on this cell.
			if occ := c.TotalOccupancy(); occ > 0 {
				const blueR, blueG, blueB = float32(60), float32(120), float32(255)
				base.R = uint8(float32(base.R)*(1-occ) + blueR*occ)
				base.G = uint8(float32(base.G)*(1-occ) + blueG*occ)
				base.B = uint8(float32(base.B)*(1-occ) + blueB*occ)
			}

			pos := rl.Vector3{X: float32(x) + 0.5, Y: h / 2, Z: float32(y) + 0.5}
			rl.DrawCube(pos, 1, h, 1, base)
			// Wireframe overlay — makes cell edges and height steps clearly visible.
			rl.DrawCubeWires(pos, 1, h, 1, rl.Color{R: 0, G: 0, B: 0, A: 40})

			// Placed pipes
			if c.ConstrDone {
				matPos := rl.Vector3{X: float32(x) + 0.5, Y: h + 0.35, Z: float32(y) + 0.5}
				rl.DrawModelEx(
					r.pipesModel,
					matPos,
					rl.Vector3{X: 0, Y: 0, Z: 0},
					0,
					rl.Vector3{X: 1, Y: 1, Z: 1},
					materialColor,
				)
				rl.DrawModelWiresEx(
					r.pipesModel,
					matPos,
					rl.Vector3{X: 0, Y: 0, Z: 0},
					0,
					rl.Vector3{X: 1, Y: 1, Z: 1},
					rl.Black,
				)
			}
		}
	}

	// pathY returns the world Y (height) for a grid cell, elevated slightly
	// above the terrain surface so path lines are always visible.
	const pathLift = float32(1.5)
	pathY := func(gx, gy int) float32 {
		if !g.InBounds(gx, gy) {
			return pathLift
		}
		return g.At(gx, gy).Height + pathLift
	}

	for _, v := range s.Vehicles {
		if v.IsDespawned() {
			continue
		}
		pos := v.GetPos()
		cx, cy := int(pos.X), int(pos.Y)
		if cx < 0 {
			cx = 0
		} else if cx >= g.Width {
			cx = g.Width - 1
		}
		if cy < 0 {
			cy = 0
		} else if cy >= g.Height {
			cy = g.Height - 1
		}
		groundH := g.At(cx, cy).Height
		var color rl.Color
		var sz rl.Vector3
		var model rl.Model
		switch v.GetType() {
		case sim.TypeExcavator:
			color = rl.White
			sz = rl.Vector3{X: 4, Y: 2, Z: 2.3}
			model = r.excavatorModel
		case sim.TypeDirtTruck:
			color = rl.White
			sz = rl.Vector3{X: 5, Y: 1.5, Z: 2}
			model = r.dirtTruckModel
		case sim.TypeCrane:
			color = rl.White
			sz = rl.Vector3{X: 17.5, Y: 4, Z: 3}
			model = r.craneModel
		case sim.TypeMaterialTruck:
			color = rl.White
			sz = rl.Vector3{X: 2.5, Y: 2, Z: 6}
			model = r.materialTruckModel
		}
		// Fetch path here so we can use it for heading before drawing.
		path := v.GetRemainingPath()

		// Compute yaw from current position toward the next waypoint.
		yaw := float32(0)
		if len(path) > 0 {
			wp := path[0]
			dx := float32(wp.X) + 0.5 - pos.X
			dz := float32(wp.Y) + 0.5 - pos.Y
			yaw = float32(math.Atan2(float64(dx), float64(dz)))*180/math.Pi + 180
		}

		rotAxis := rl.Vector3{X: 0, Y: 1, Z: 0}
		scale := rl.Vector3{X: 1, Y: 1, Z: 1}
		vpos := rl.Vector3{X: pos.X, Y: groundH + sz.Y/2, Z: pos.Y}
		rl.DrawModelEx(model, vpos, rotAxis, yaw, scale, color)
		rl.DrawModelWiresEx(model, vpos, rotAxis, yaw, scale, rl.Gray)

		// Material trucks: draw a pipe on the truck bed for each
		// unit of cargo.  Two pipes sit in a row; removing one is
		// immediately visible when the crane takes it.
		if v.GetType() == sim.TypeMaterialTruck {
			if mt, ok := v.(*sim.MaterialTruck); ok && mt.Cargo > 0 {
				// Centre the row of pipes along the trailer length (Z axis).
				const pipeLen = float32(0.6)
				const gap = float32(0.5)
				total := float32(mt.Cargo)
				totalSpan := total*pipeLen + (total-1)*gap
				startZ := pos.Y - totalSpan/2 + pipeLen/2
				for i := 0; i < mt.Cargo; i++ {
					z := startZ + float32(i)*(pipeLen+gap)
					position := rl.Vector3{X: pos.X, Y: 82, Z: z}
					rl.DrawModel(r.pipesModel, position, 1, rl.White)
					rl.DrawModelWires(r.pipesModel, position, 1, rl.Black)
				}
			}
		}

		// Draw remaining path as connected line segments above the terrain.
		if len(path) > 0 {
			lineColor := rl.Color{R: color.R, G: color.G, B: color.B, A: 180}
			// Line from vehicle position to first waypoint.
			from := rl.Vector3{X: pos.X, Y: groundH + pathLift, Z: pos.Y}
			wp0 := path[0]
			to := rl.Vector3{X: float32(wp0.X) + 0.5, Y: pathY(wp0.X, wp0.Y), Z: float32(wp0.Y) + 0.5}
			rl.DrawLine3D(from, to, lineColor)
			// Remaining waypoint-to-waypoint segments.
			for i := 1; i < len(path); i++ {
				wp := path[i]
				next := rl.Vector3{X: float32(wp.X) + 0.5, Y: pathY(wp.X, wp.Y), Z: float32(wp.Y) + 0.5}
				rl.DrawLine3D(to, next, lineColor)
				to = next
			}
		}
	}

	rl.EndMode3D()

	// HUD
	rl.DrawText(fmt.Sprintf("Sim Time: %.1fs", s.SimTime), 10, 10, 20, rl.Black)
	phase := 1
	if s.Phase.Phase1Complete {
		phase = 2
	}
	rl.DrawText(fmt.Sprintf("Phase: %d", phase), 10, 35, 20, rl.Black)
	rl.DrawText(fmt.Sprintf("Excavation:   %d/%d", s.Phase.ExcavDone, s.Phase.TotalExcavation), 10, 60, 20, rl.Black)
	rl.DrawText(fmt.Sprintf("Construction: %d/%d", s.Phase.ConstrDone, s.Phase.TotalConstruct), 10, 85, 20, rl.Black)
	active := 0
	for _, v := range s.Vehicles {
		if !v.IsDespawned() {
			active++
		}
	}
	rl.DrawText(fmt.Sprintf("Vehicles: %d", active), 10, 110, 20, rl.Black)
	rl.DrawText(fmt.Sprintf("FPS: %d", rl.GetFPS()), 10, 135, 20, rl.Black)
	orbitLabel := "off"
	if r.autoOrbit {
		orbitLabel = "ON"
	}
	rl.DrawText(fmt.Sprintf("[UP]/[DOWN] height  |  [LEFT]/[RIGHT] pan  |  left-drag: orbit  |  scroll: zoom  |  [O] auto-orbit: %s  |  [P] pause", orbitLabel), 10, int32(r.height)-30, 18, rl.DarkGray)


	rl.EndDrawing()
}

func (r *Renderer) Close() {
	rl.UnloadModel(r.materialModel)
	rl.UnloadModel(r.excavatorModel)
	rl.UnloadModel(r.dirtTruckModel)
	rl.UnloadModel(r.craneModel)
	rl.UnloadModel(r.materialTruckModel)
	rl.UnloadModel(r.pipesModel)
	rl.CloseWindow()
}
