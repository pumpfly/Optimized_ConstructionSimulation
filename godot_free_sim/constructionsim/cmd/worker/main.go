package main

import (
	"bytes"
	"constructionsim/render"
	"constructionsim/sim"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func main() {
	heightmapFlag := flag.String("heightmap", "", "Path to heightmap PNG")
	fastFlag := flag.Bool("fast", false, "Headless fast mode")
	flag.Parse()

	if *heightmapFlag == "" {
		fmt.Fprintln(os.Stderr, "Usage: worker --heightmap <path> [--fast]")
		os.Exit(1)
	}

	g, err := sim.LoadGrid(*heightmapFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "load grid:", err)
		os.Exit(1)
	}

	for {
		work, err := getWork()
		if err != nil {
			fmt.Fprintln(os.Stderr, "get work:", err)
			time.Sleep(time.Second)
			continue
		}
		if work == nil {
			// "end"
			return
		}

		metrics := runSimulation(g, *work, *fastFlag)

		if err := postHandover(work.ID, metrics); err != nil {
			fmt.Fprintln(os.Stderr, "handover:", err)
		}
	}
}

func getWork() (*sim.WorkData, error) {
	for {
		resp, err := http.Get("http://127.0.0.1:7050/work")
		if err != nil {
			return nil, err
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return nil, err
		}
		s := strings.TrimSpace(string(body))
		if s == "end" {
			return nil, nil
		}
		if s == "wait" {
			time.Sleep(time.Second)
			continue
		}
		var work sim.WorkData
		if err := json.Unmarshal(body, &work); err != nil {
			return nil, fmt.Errorf("unmarshal work: %w", err)
		}
		return &work, nil
	}
}

func postHandover(id string, metrics sim.Metrics) error {
	data, err := json.Marshal(metrics)
	if err != nil {
		return err
	}
	url := fmt.Sprintf("http://127.0.0.1:7050/handover?id=%s", id)
	resp, err := http.Post(url, "application/json", bytes.NewReader(data))
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func runSimulation(g *sim.Grid, work sim.WorkData, fast bool) sim.Metrics {
	s := sim.NewSimulation(g, work)

	if fast {
		for !s.IsDone() {
			s.Tick(sim.SimStep)
		}
		return s.Metrics()
	}

	// Visual mode
	r := render.NewRenderer(1280, 720, g)
	defer r.Close()

	accumulator := float32(0)
	for !r.ShouldClose() && !s.IsDone() {
		realDT := r.GetFrameTime()
		if realDT > 0.05 {
			realDT = 0.05
		}
		if !r.Paused {
			accumulator += realDT * 100.0
			for accumulator >= sim.SimStep {
				s.Tick(sim.SimStep)
				accumulator -= sim.SimStep
				if s.IsDone() {
					break
				}
			}
		}
		r.Draw(s)
	}
	return s.Metrics()
}
