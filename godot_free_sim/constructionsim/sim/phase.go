package sim

type PhaseManager struct {
	TotalExcavation  int
	TotalConstruct   int
	ExcavDone        int
	ConstrDone       int
	Phase1Complete   bool
	Phase2Complete   bool
	Phase1CompleteAt float32
	Phase2CompleteAt float32
}

func NewPhaseManager(g *Grid) *PhaseManager {
	pm := &PhaseManager{}
	for y := 0; y < g.Height; y++ {
		for x := 0; x < g.Width; x++ {
			c := &g.Cells[y][x]
			if c.Excavate {
				pm.TotalExcavation++
			}
			if c.PipePlacementCell {
				pm.TotalConstruct++
			}
		}
	}
	return pm
}

func (pm *PhaseManager) RecordExcavation(simTime float32) {
	pm.ExcavDone++
}

func (pm *PhaseManager) RecordConstruction(simTime float32) {
	pm.ConstrDone++
}

func (pm *PhaseManager) CheckPhase1(simTime float32) bool {
	if pm.Phase1Complete {
		return false
	}
	if pm.TotalExcavation == 0 || pm.ExcavDone >= pm.TotalExcavation {
		pm.Phase1Complete = true
		pm.Phase1CompleteAt = simTime
		return true
	}
	return false
}

func (pm *PhaseManager) CheckPhase2(simTime float32) bool {
	if pm.Phase2Complete {
		return false
	}
	if !pm.Phase1Complete {
		return false
	}
	if pm.TotalConstruct == 0 || pm.ConstrDone >= pm.TotalConstruct {
		pm.Phase2Complete = true
		pm.Phase2CompleteAt = simTime
		return true
	}
	return false
}
