package main

import (
	"strings"

	"rsc.io/qr"
)

const quiet = 4 // light modules around the code

// renderQR draws the code with two modules per character. Colors are forced (white on black,
// light modules filled) so it scans on both dark and light terminal themes.
func renderQR(text string) (string, error) {
	c, err := qr.Encode(text, qr.M)
	if err != nil {
		return "", err
	}
	light := func(x, y int) bool { return !c.Black(x, y) } // Black is false outside the code
	var b strings.Builder
	for y := -quiet; y < c.Size+quiet; y += 2 {
		b.WriteString("\x1b[40;97m")
		for x := -quiet; x < c.Size+quiet; x++ {
			switch top, bottom := light(x, y), light(x, y+1); {
			case top && bottom:
				b.WriteRune('█')
			case top:
				b.WriteRune('▀')
			case bottom:
				b.WriteRune('▄')
			default:
				b.WriteByte(' ')
			}
		}
		b.WriteString("\x1b[0m\n")
	}
	return b.String(), nil
}
