# Construction Simulation — Implementation Specification

Simulate a tightly limited construction site, for use in a genetic algorithm.
Built in Go with raylib-go for optional 3D visualization.

## 1. Worker Flow

Each process execution is a worker:

1. Request `http://127.0.0.1:7050/work` (GET) to get work
2. If response body is `"end"` → terminate
3. If response body is `"wait"` → sleep 1s, goto 1
4. Otherwise parse work data (JSON), run simulation with it
5. POST results to `http://127.0.0.1:7050/handover?id=<work_id>` with metrics
   as JSON body
6. Goto 1

## 2. CLI Arguments

```
worker --heightmap ./terrain.png --spawn 50,50 [--fast]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--heightmap` | yes | Path to heightmap PNG. Each pixel = 1m². |
| `--spawn` | yes | Comma-separated X,Y grid coordinates for the single spawn/entry point. |
| `--fast` | no | Headless mode. No window. Simulation runs as fast as CPU allows. |

When `--fast` is absent, a raylib window opens showing the simulation at 100x
realtime.

## 3. Work Data

```json
{
    "id": "unique_id_string",
    "schedule": {
        "0":   ["excavator", "dirt_truck", "dirt_truck"],
        "30":  ["excavator", "dirt_truck"],
        "120": ["crane", "material_truck", "material_truck"]
    }
}
```

Schedule keys are timestamps in sim-seconds (float-compatible). Values are
arrays of vehicle type strings. Vehicles spawn at the spawn point at the given
sim-time.

## 4. Heightmap

RGB PNG image of arbitrary pixel dimensions. Each pixel = one grid cell = 1m².

| Channel | Meaning |
|---------|---------|
| BLUE | Height in meters (0–255). Base level = 80. |
| RED | Excavation marker. Value > 0 → cell must be excavated 1m down. |
| GREEN | Construction marker. Value > 0 → crane must place one material here. |

Loaded once at startup. The image data is used to build the grid; the image
itself is not referenced again.

## 5. Simulation Timing

The simulation uses a **fixed timestep** to ensure determinism across modes and
hardware.

```
SIM_STEP = 0.05s  (50ms of sim-time per tick)
```

### Visual mode (no --fast)

```
each frame:
    accumulator += real_delta * 100.0    // 100x realtime
    while accumulator >= SIM_STEP:
        sim_tick(SIM_STEP)
        accumulator -= SIM_STEP
    render()
```

At 60 FPS this runs ~33 sim ticks per frame. Raylib window is open.
`rl.SetTargetFPS(60)`.

### Fast mode (--fast)

```
loop:
    sim_tick(SIM_STEP)
    // no rendering, no frame delay
```

No window. Pure computation. One tick per iteration, as fast as the CPU allows.

### Why this works

Max vehicle speed is 4 m/s. Per tick: `4 * 0.05 = 0.2m`. Cell size is 1m.
Movement per tick is always < 1 cell. No overshoot. Occupancy is checked every
tick. No special multi-waypoint consumption needed.

## 6. Grid and Navigation

### Grid

2D array of cells built from the heightmap. Each cell stores:

```go
type Cell struct {
    Height       float32          // from BLUE channel
    Excavate     bool             // RED > 0
    Construct    bool             // GREEN > 0
    ExcavDone    bool             // true after excavation complete
    ConstrDone   bool             // true after material placed
    Reserved     int              // vehicle ID that reserved this cell for excavation, -1 if none
    Occupancy    map[int]float32  // vehicle_id → contribution (0..1)
}
```

Grid coordinates: (0,0) is top-left pixel of the heightmap. X increases right,
Y increases down. Cell (x,y) has its center at world position (x+0.5, y+0.5).
A cell spans from (x, y) to (x+1, y+1) in world units.

### A* Pathfinding

Custom A* implementation in Go operating on the grid.

**Edge passability:** A connection between two adjacent cells (4-directional +
diagonal) exists only if `abs(height_a - height_b) <= 1`. This is directional —
cell A→B may be passable while A→C is not, even though B and C are both
neighbors of A.

**Diagonal connections** additionally require that both shared-edge orthogonal
neighbors are passable (no corner cutting through walls). Diagonal cost = √2,
orthogonal cost = 1.

**Occupancy-weighted cost:** When pathfinding, cell cost is multiplied by
`1 + occupancy * 10`. Occupied cells are expensive but never impassable via
cost alone (the vehicle suffers slowdown instead).

**Excavation updates the nav graph:** When a cell is excavated (height
decreases by 1), recheck passability of all 8 edges involving that cell. Add
or remove connections as needed.

### When vehicles pathfind

- On spawn (initial destination)
- On task completion (new destination)
- When the next ~3 cells on their current path exceed the occupancy repath
  threshold (0.6 from other vehicles). A single repath is triggered: A* from
  current cell to the first cell on the old path that is below threshold.
  The detour replaces the blocked section. No re-validation of the detour.

## 7. Occupancy System

### Per-vehicle tracking

Each cell's occupancy is a `map[int]float32` keyed by vehicle ID. When a
vehicle checks occupancy, it sums all entries except its own.

### Occupancy formula

For a vehicle at position P with radius R, for each cell C whose center is
within R of P:

```
contribution = 1.0 - (dist(P, C_center) / R)
```

Clamped to [0, 1]. Full occupancy at vehicle center, linear falloff to 0 at
edge of radius.

### Dirty tracking

Each vehicle remembers which cells it wrote to last tick. On the new tick, it
clears its own entries from those cells, computes new cells, writes new entries.
No global clear needed.

### Special occupancy

- **Cells being actively excavated:** The excavator sets occupancy 1.0 on the
  cell being dug (keyed to a synthetic ID, use `math.MinInt32` to avoid
  collision with vehicle IDs or the reservation sentinel -1). Removed when
  excavation of that cell completes.
- **Spawn immunity:** Newly spawned vehicles do not *cause* occupancy for their
  first 1 second of sim-time (20 ticks). They still *react to* others'
  occupancy. This prevents spawn gridlock.

### Slowdown from occupancy

When a vehicle is on a cell with others' occupancy > 0:

```
speed_multiplier = max(0.05, 1.0 - others_occupancy)
effective_speed = base_speed * speed_multiplier
```

At occupancy 1.0 from others, vehicle moves at 5% speed (near standstill).
At 0, full speed.

## 8. Vehicle Specifications

### Speeds (real-world m/s)

| Vehicle | Speed | Occupancy Radius |
|---------|-------|-----------------|
| Excavator | 4.4 m/s (16 km/h) | 2.5m |
| Dirt Truck | 5.0 m/s (18 km/h)| 1.5m |
| Crane | 2.5 m/s (10 km/h) | 3.5m |
| Material Truck | 4.0 m/s | 1.5m |

### Capacities and timings

| Parameter | Value |
|-----------|-------|
| Dirt truck capacity | 3 m³ |
| Material truck capacity | 2 materials |
| Excavation time per cell | 30s sim-time |
| Dirt truck unload time | 15s sim-time |
| Crane placement time per material | 45s sim-time |
| Material truck restock time | 20s sim-time |
| Excavator inactivity timeout | 60s sim-time |
| Dirt truck search retry interval | 10s sim-time |
| Material truck wait-near-spawn retry | 15s sim-time |
| Crane working radius | 30m (distance, not cells) |
| Crane max assigned material trucks | 5 |
| Excavator max assigned dirt trucks | 2 |
| Excavator work range | 1.5m from cell center |
| "Near spawn" threshold | 3m from spawn point |
| Sim timeout | 3600s sim-time |

## 9. Vehicle Behaviors

All vehicles are state machines. Update order each tick: process vehicles in
spawn order (deterministic). Within the same schedule timestamp, spawn order
follows array index. RNG seeded from work ID for reproducibility.

### 9.1 Excavator States

```
SPAWNED
  → if near spawn: pathfind to random point within 5-15m of spawn
  → search for next unreserved excavation cell in scanline order
    (top-to-bottom, left-to-right)
  → if found: reserve it, pathfind to within 1.5m of it → MOVING_TO_CELL
  → if none found: pathfind to spawn → LEAVING

MOVING_TO_CELL
  → follow path, check occupancy ahead each tick
  → when within 1.5m of target cell center → WAITING_FOR_TRUCK

WAITING_FOR_TRUCK
  → wait until an assigned dirt truck is within 2m
  → when truck nearby → EXCAVATING
  → inactivity timeout (60s): dirt trucks unassign themselves (truck-side logic)

EXCAVATING
  → spend 30s sim-time
  → set target cell occupancy to 1.0 (synthetic ID)
  → on completion: mark cell ExcavDone, update cell height (height -= 1),
    update nav graph edges around cell, remove synthetic occupancy,
    fill active truck's cargo += 1 m³ (the active truck is the one
    within 2m that triggered excavation; the second assigned truck is
    the waiting truck and becomes active when the first leaves)
  → search for next unreserved cell (scanline order)
  → if found: reserve it, pathfind → MOVING_TO_CELL
  → if none: pathfind to spawn → LEAVING

LEAVING
  → follow path to spawn
  → when within 3m of spawn → DESPAWNED (remove from sim)
```

### 9.2 Dirt Truck States

```
SPAWNED
  → search for excavator to assign to (priority system below)

SEARCHING
  → apply excavator priority:
      1. No assigned trucks AND finished digging (waiting for truck)
      2. No assigned trucks
      3. Has one truck (become second/waiting truck)
  → if found: assign self to excavator, pathfind to it → MOVING_TO_EXCAVATOR
  → if not found:
      → if within 3m of spawn: pathfind to random point 5-15m from spawn,
        move there first
      → once away from spawn (or already was): wait 10s sim-time, then
        search again

MOVING_TO_EXCAVATOR
  → follow path toward assigned excavator
  → when within 2m of excavator → FOLLOWING

FOLLOWING
  → "stupid follow": each tick, move directly toward excavator position
    at own speed. No pathfinding. Ignores height (won't happen per spec).
    Still causes and reacts to occupancy.
  → excavator fills cargo when it finishes a cell (excavator-side logic)
  → when cargo == capacity (3 m³) → RETURNING
  → if excavator inactivity timeout (60s no dig/move): unassign → SEARCHING
  → if phase1 complete signal: immediately → LEAVING

RETURNING
  → pathfind to spawn
  → when within 3m of spawn → UNLOADING

UNLOADING
  → spend 15s sim-time
  → cargo = 0
  → → SEARCHING

LEAVING
  → pathfind to spawn
  → when within 3m of spawn → DESPAWNED
```

### 9.3 Crane States

```
SPAWNED
  → if phase 1 not complete: pathfind to random point 5-15m from spawn
    → WAITING_FOR_PHASE2

WAITING_FOR_PHASE2
  → idle until phase 1 completes
  → on phase 1 complete → POSITIONING

POSITIONING
  → find nearest unfinished construction cell
  → pathfind toward it
  → after each cell step: check if ALL unfinished construction cells are
    within 30m of current position
  → if all in range: stop moving → WORKING
  → if reached target cell and not all in range: → WORKING
    (will need to reposition later for remaining cells)

WORKING
  → find next unfinished construction cell within 30m
  → if none in range: → POSITIONING (move to reach more)
  → if no material trucks assigned with materials: wait (check each tick)
  → take 1 material from nearest assigned truck within 3m that has
    materials (truck cargo -= 1)
  → spend 45s sim-time placing
  → mark cell ConstrDone
  → if all construction cells done: → phase 2 complete signal → LEAVING
  → repeat (find next cell in range)

LEAVING
  → pathfind to spawn
  → when within 3m of spawn → DESPAWNED
```

### 9.4 Material Truck States

```
SPAWNED
  → cargo = 2 (starts full)
  → if phase 1 not complete: pathfind to random point 5-15m from spawn
    → WAITING_FOR_PHASE2

WAITING_FOR_PHASE2
  → idle until phase 1 completes
  → → SEARCHING

SEARCHING
  → try to assign self to crane (if crane has < 5 trucks)
  → if assigned: pathfind to crane → MOVING_TO_CRANE
  → if not: pathfind to random point 5-15m from spawn, wait 15s, retry

MOVING_TO_CRANE
  → follow path to crane
  → when within 2m of crane → ATTENDING

ATTENDING
  → stay near crane (stupid follow, like dirt trucks)
  → crane takes materials (crane-side logic, sets truck cargo -= 1)
  → when cargo == 0: unassign from crane → RETURNING

RETURNING
  → pathfind to spawn
  → when within 3m of spawn → RESTOCKING

RESTOCKING
  → spend 20s sim-time
  → cargo = 2
  → → SEARCHING

LEAVING
  → pathfind to spawn
  → when within 3m of spawn → DESPAWNED
```

## 10. Phase Management

### Phase 1: Excavation

- Active from sim start.
- Tracks `excavated_count` vs `total_excavation_cells` (count of RED > 0 pixels).
- Complete when `excavated_count == total_excavation_cells`.
- On completion: all excavators and dirt trucks receive leave signal. They
  immediately transition to LEAVING state regardless of current state.
- If there are zero excavation cells, phase 1 is immediately complete at sim
  start.

### Phase 2: Construction

- Begins when phase 1 completes.
- Crane and material trucks that were in WAITING_FOR_PHASE2 transition to their
  active states.
- Tracks `constructed_count` vs `total_construction_cells` (count of GREEN > 0
  pixels).
- Complete when `constructed_count == total_construction_cells`.
- On completion: all remaining vehicles receive leave signal → LEAVING.
- If there are zero construction cells, phase 2 is immediately complete.

### Termination

Simulation ends when all vehicles have despawned (reached spawn and removed).

### Timeout

If sim-time exceeds 3600s, the simulation stops immediately and reports
`sim_time * 1.5` as the result time (penalty for non-completion).

## 11. Handover

POST to `http://127.0.0.1:7050/handover?id=<work_id>`

```json
{
    "time": 847.35,
    "phase1_time": 412.10,
    "phase2_time": 435.25,
    "total_vehicles": 12,
    "timeout": false
}
```

The primary metric is `time` (total sim-time to completion, or penalized time
on timeout). Additional fields are low-cost extras for analytics.

On timeout: `time` = sim_time * 1.5 (penalized). `phase1_time` = actual
phase 1 duration (or total sim_time if phase 1 never completed).
`phase2_time` = actual phase 2 duration (or 0 if phase 2 never started).
The penalty multiplier applies only to the `time` field.

## 12. Rendering (Visual Mode Only)

Only active when `--fast` is NOT set. Uses raylib-go.

### Window

- Resolution: 1280x720 (or configurable)
- Camera: 3D perspective, free-look for debugging. Arrow keys / mouse to orbit.

### Terrain

Each grid cell rendered as `rl.DrawCube()`:
- Position: `(cell_x, cell_height/2, cell_y)` (centered vertically)
- Size: `(1, cell_height, 1)`
- Color: base gray, RED tint for excavation cells, GREEN tint for construction
  cells. Completed cells get a distinct color (darker/muted).

### Vehicles

Each vehicle rendered as `rl.DrawCube()` at its position:

| Vehicle | Color | Size (w,h,d) |
|---------|-------|--------------|
| Excavator | Yellow | 2, 1.5, 2 |
| Dirt Truck | Orange | 1.5, 1, 2.5 |
| Crane | Red | 2.5, 3, 2.5 |
| Material Truck | Blue | 1.5, 1, 2.5 |

Vehicle Y position = terrain height at their current cell + half their height
(sitting on top of terrain).

### HUD

Minimal text overlay with `rl.DrawText()`:
- Sim time
- Phase (1 or 2)
- Excavation progress (X/Y cells)
- Construction progress (X/Y cells)
- Vehicle count

## 13. Project Structure

```
constructionsim/
├── SPEC.md
├── go.mod
├── cmd/
│   └── worker/
│       └── main.go          // CLI parsing, orchestrator HTTP, main loop
├── sim/
│   ├── grid.go              // Grid, Cell, heightmap loading, A*
│   ├── occupancy.go         // Occupancy system
│   ├── vehicle.go           // Vehicle interface, base struct, movement
│   ├── excavator.go         // Excavator state machine
│   ├── dirt_truck.go        // Dirt truck state machine
│   ├── crane.go             // Crane state machine
│   ├── material_truck.go    // Material truck state machine
│   ├── phase.go             // Phase manager
│   └── simulation.go        // Simulation orchestrator (tick loop, spawn scheduling)
└── render/
    └── renderer.go          // Raylib rendering (only imported when not --fast)
```

The `sim/` package has zero raylib dependency. `render/` imports both `sim/`
and raylib. `cmd/worker/main.go` conditionally uses `render/` based on
`--fast`.

## 14. Idle wander behavior

All vehicles that cannot immediately start work must move away from spawn to
prevent blocking. The target is a random walkable cell 5–15m from spawn
(within grid bounds, passable height). On reaching it, the vehicle idles there
until its retry timer fires.

If the vehicle is ALREADY away from spawn (> 3m) when it fails to find work,
it stays put and waits.
