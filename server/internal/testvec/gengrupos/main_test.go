package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestVectorsUpToDate regenerates the group vectors in memory and compares them with
// docs/vetores/grupos. A difference means the code changed without regenerating.
func TestVectorsUpToDate(t *testing.T) {
	_, f, _, _ := runtime.Caller(0)
	base := filepath.Join(filepath.Dir(f), "..", "..", "..", "..", "docs", "vetores")
	files, err := generate(base)
	if err != nil {
		t.Fatal(err)
	}
	again, err := generate(base)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range files {
		if !bytes.Equal(want, again[name]) {
			t.Errorf("%s: saída muda entre execuções", name)
		}
		got, err := os.ReadFile(filepath.Join(base, "grupos", name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("docs/vetores/grupos/%s desatualizado: rode go run ./internal/testvec/gengrupos ../docs/vetores", name)
		}
	}
}
