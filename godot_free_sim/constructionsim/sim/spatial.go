package sim

// sepBucketSize must be >= the largest possible separation distance
// (crane radius 5 + crane radius 5 = 10) so that a 3×3 bucket neighborhood
// always contains every vehicle within interaction range.
const sepBucketSize = 11

// SpatialIndex is a coarse grid that maps vehicles to buckets for O(1)
// neighbour lookups in the steering separation loop.
type SpatialIndex struct {
	buckets map[Point][]Updatable
}

func newSpatialIndex() *SpatialIndex {
	return &SpatialIndex{buckets: make(map[Point][]Updatable)}
}

func (si *SpatialIndex) bucketOf(pos Vec2) Point {
	return Point{int(pos.X) / sepBucketSize, int(pos.Y) / sepBucketSize}
}

// Build rebuilds the index from the current vehicle positions.
// Call once per tick, before any FollowPath calls.
func (si *SpatialIndex) Build(vehicles []Updatable) {
	for k := range si.buckets {
		delete(si.buckets, k)
	}
	for _, v := range vehicles {
		if v.IsDespawned() {
			continue
		}
		b := si.bucketOf(v.GetPos())
		si.buckets[b] = append(si.buckets[b], v)
	}
}

// Neighbors returns all non-despawned vehicles in the 3×3 bucket neighbourhood
// around pos. Because sepBucketSize >= maxSepDist, this is guaranteed to
// include every vehicle that could influence the separation force.
func (si *SpatialIndex) Neighbors(pos Vec2) []Updatable {
	b := si.bucketOf(pos)
	var out []Updatable
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			out = append(out, si.buckets[Point{b.X + dx, b.Y + dy}]...)
		}
	}
	return out
}
