package main

import (
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"math"
	"os"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const (
	chartW      = 1050
	chartH      = 600
	marginLeft  = 80
	marginRight = 40
	marginTop   = 60
	marginBot   = 70
)

var (
	colorBackground = color.NRGBA{255, 255, 255, 255}
	colorAxis       = color.NRGBA{60, 60, 60, 255}
	colorGrid       = color.NRGBA{220, 220, 220, 255}
	colorBest       = color.NRGBA{34, 139, 34, 255}  // green
	colorAvg        = color.NRGBA{30, 100, 200, 255} // blue
	colorWorst      = color.NRGBA{200, 50, 50, 255}  // red
	colorText       = color.NRGBA{40, 40, 40, 255}
)

// setPixel sets a pixel if inside bounds.
func setPixel(img *image.NRGBA, x, y int, c color.NRGBA) {
	if x >= 0 && x < img.Bounds().Max.X && y >= 0 && y < img.Bounds().Max.Y {
		img.SetNRGBA(x, y, c)
	}
}

// drawLine draws a 1px line using Bresenham's algorithm.
func drawLine(img *image.NRGBA, x0, y0, x1, y1 int, c color.NRGBA) {
	dx := abs(x1 - x0)
	dy := abs(y1 - y0)
	sx, sy := 1, 1
	if x0 > x1 {
		sx = -1
	}
	if y0 > y1 {
		sy = -1
	}
	err := dx - dy
	for {
		setPixel(img, x0, y0, c)
		if x0 == x1 && y0 == y1 {
			break
		}
		e2 := 2 * err
		if e2 > -dy {
			err -= dy
			x0 += sx
		}
		if e2 < dx {
			err += dx
			y0 += sy
		}
	}
}

// drawThickLine draws a line with the given pixel thickness.
func drawThickLine(img *image.NRGBA, x0, y0, x1, y1, thickness int, c color.NRGBA) {
	half := thickness / 2
	for t := -half; t <= half; t++ {
		dx := x1 - x0
		dy := y1 - y0
		if abs(dx) >= abs(dy) {
			drawLine(img, x0, y0+t, x1, y1+t, c)
		} else {
			drawLine(img, x0+t, y0, x1+t, y1, c)
		}
	}
}

// drawLabel draws a string using the 7x13 basic font.
func drawLabel(img *image.NRGBA, x, y int, label string, c color.NRGBA) {
	d := &font.Drawer{
		Dst:  img,
		Src:  image.NewUniform(c),
		Face: basicfont.Face7x13,
		Dot:  fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y)},
	}
	d.DrawString(label)
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// saveFitnessChart renders best/avg/worst fitness curves and writes a JPEG.
// Y-axis shows fitness in hours (dividing seconds by 3600).
func saveFitnessChart(history []genStats, path string) error {
	if len(history) == 0 {
		return nil
	}

	img := image.NewNRGBA(image.Rect(0, 0, chartW, chartH))

	// Fill background
	for y := 0; y < chartH; y++ {
		for x := 0; x < chartW; x++ {
			img.SetNRGBA(x, y, colorBackground)
		}
	}

	plotW := chartW - marginLeft - marginRight
	plotH := chartH - marginTop - marginBot

	// Fixed Y range: 0 to 15 h in 1.5 h steps
	yMin := 0.0
	yMax := 15.0

	maxGen := len(history) - 1
	if maxGen < 1 {
		maxGen = 1
	}

	// Map data coordinates to pixel coordinates
	toPixel := func(gen int, fitnessHours float64) (int, int) {
		px := marginLeft + int(float64(gen)/float64(maxGen)*float64(plotW))
		py := marginTop + int((1.0-(fitnessHours-yMin)/(yMax-yMin))*float64(plotH))
		return px, py
	}

	// Horizontal grid lines: fixed ticks every 1.5 h from 0 to 15 h
	for i := 0; i <= 10; i++ {
		fy := float64(i) * 1.5
		_, py := toPixel(0, fy)
		drawLine(img, marginLeft, py, marginLeft+plotW, py, colorGrid)
		h := int(fy)
		m := int((fy - float64(h)) * 60)
		label := fmt.Sprintf("%dh%02dm", h, m)
		drawLabel(img, marginLeft-60, py+4, label, colorText)
	}

	// Vertical grid lines
	numXTicks := 10
	if maxGen < numXTicks {
		numXTicks = maxGen
	}
	for i := 0; i <= numXTicks; i++ {
		gen := int(math.Round(float64(i) / float64(numXTicks) * float64(maxGen)))
		px, _ := toPixel(gen, yMin)
		drawLine(img, px, marginTop, px, marginTop+plotH, colorGrid)
		label := fmt.Sprintf("%d", gen)
		drawLabel(img, px-3, marginTop+plotH+16, label, colorText)
	}

	// Draw the three curves
	type curve struct {
		values []float64
		col    color.NRGBA
	}
	curves := []curve{
		{make([]float64, len(history)), colorWorst},
		{make([]float64, len(history)), colorAvg},
		{make([]float64, len(history)), colorBest},
	}
	for i, g := range history {
		curves[0].values[i] = g.WorstSeconds / 3600.0
		curves[1].values[i] = g.AvgSeconds / 3600.0
		curves[2].values[i] = g.BestSeconds / 3600.0
	}
	for _, c := range curves {
		for i := 1; i < len(c.values); i++ {
			x0, y0 := toPixel(i-1, c.values[i-1])
			x1, y1 := toPixel(i, c.values[i])
			drawThickLine(img, x0, y0, x1, y1, 2, c.col)
		}
	}

	// Axes (drawn on top of grid)
	drawLine(img, marginLeft, marginTop, marginLeft, marginTop+plotH, colorAxis)
	drawLine(img, marginLeft, marginTop+plotH, marginLeft+plotW, marginTop+plotH, colorAxis)

	// Title
	title := fmt.Sprintf("GA Fitness %d Generations", len(history))
	drawLabel(img, chartW/2-len(title)*3, marginTop-28, title, colorText)

	// Axis labels — placed at the end point of each axis
	labelWidth := len("Generation") * 4
	drawLabel(img, marginLeft+plotW-labelWidth, chartH-5, "Generation", colorText)
	drawLabel(img, marginLeft+4, marginTop-14, "Fitness (h)", colorText)

	// Legend — bottom right
	legendX := marginLeft + plotW - 110
	legendY := marginTop - 45
	drawThickLine(img, legendX, legendY, legendX+20, legendY, 2, colorBest)
	drawLabel(img, legendX+24, legendY+4, "Best", colorBest)
	drawThickLine(img, legendX, legendY+18, legendX+20, legendY+18, 2, colorAvg)
	drawLabel(img, legendX+24, legendY+22, "Average", colorAvg)
	drawThickLine(img, legendX, legendY+36, legendX+20, legendY+36, 2, colorWorst)
	drawLabel(img, legendX+24, legendY+40, "Worst", colorWorst)

	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return jpeg.Encode(f, img, &jpeg.Options{Quality: 92})
}
